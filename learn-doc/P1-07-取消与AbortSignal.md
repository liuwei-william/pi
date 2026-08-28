# P1-07 · AbortSignal 与取消

> 目标:掌握 Pi 里出现 272 次的横切关注点,理解"协作式取消"的设计
> 前置:[P1-02](P1-02-异步与Promise.md)、[P1-06](P1-06-异步迭代.md)
> 读完你应该能:给自己的异步函数正确加上取消支持,并解释"取消不等于停止"

---

## 0. 为什么这一篇很重要

`AbortSignal` 在 Pi 的 `ai` + `agent` + `coding-agent` 三个包里出现 **272 次**。几乎每一个异步函数的签名里都有它。

**原因很具体**:

- 一次 LLM 请求可能跑几十秒,而且**按 token 收费**
- 用户按 Ctrl+C 时,不只要停止显示,还要**真的掐断 HTTP 连接**,否则钱照扣
- 一个 agent 回合可能同时有:HTTP 流、多个工具执行、shell 子进程、定时器——**全都要能停**

Java 里对应的是 `Thread.interrupt()` + `Future.cancel()`,但那是"半自动"的(阻塞方法会自动响应中断)。**JS 的取消是 100% 手工的**:你不主动检查,就永远停不下来。

---

## 1. 基础 API:三个东西

```ts
const controller = new AbortController();   // ① 遥控器(生产者持有)
const signal = controller.signal;           // ② 信号(消费者持有)

controller.abort();                         // ③ 按下取消
controller.abort(new Error("用户取消"));     //    可以带原因
```

**核心设计:控制权和感知权分离。**

- 谁能取消 → 持有 `controller`
- 谁需要响应取消 → 只拿到 `signal`(只读,没法自己 abort)

这跟 Java 里传 `Future` 出去(调用方能 cancel)vs 传 `CancellationToken`(只能观察)是一个思路。

`signal` 上有三样东西:

```ts
signal.aborted            // boolean —— 已经取消了吗
signal.reason             // 取消原因(abort() 传的参数,默认是 AbortError)
signal.throwIfAborted()   // 已取消就抛异常,没取消就啥也不做
signal.addEventListener("abort", handler)   // 监听取消事件
```

---

## 2. 响应取消的三种方式

这是本篇最需要形成肌肉记忆的部分。

### 方式一:主动轮询(在关键节点检查)

```ts
async function exportOrders(orderIds: string[], signal?: AbortSignal): Promise<Order[]> {
   const result: Order[] = [];
   for (const id of orderIds) {
      if (signal?.aborted) {                    // ← 每轮检查
         throw new Error("导出已取消");
      }
      result.push(await fetchOrder(id));
   }
   return result;
}
```

更简洁的写法用 `throwIfAborted()`:

```ts
for (const id of orderIds) {
   signal?.throwIfAborted();                    // ← 一行搞定
   result.push(await fetchOrder(id));
}
```

**检查点放哪?** 每个可能耗时的操作**之前**,特别是循环里。

Pi 的例子([packages/ai/src/providers/anthropic.ts:18](../packages/ai/src/providers/anthropic.ts#L18)):

```ts
resolve: async ({ ctx, credential, signal }) => {
   signal.throwIfAborted();                     // 开头检查
   if (credential?.key) {
      return { auth: { apiKey: credential.key }, ... };
   }

   const authToken = await ctx.env(ANTHROPIC_AUTH_TOKEN_ENV);
   signal.throwIfAborted();                     // 每次 await 之后再检查
   if (authToken) { ... }

   for (const envVar of [ANTHROPIC_OAUTH_TOKEN_ENV, ANTHROPIC_API_KEY_ENV]) {
      const apiKey = await ctx.env(envVar);
      signal.throwIfAborted();                  // 循环里也检查
      if (apiKey) return { auth: { apiKey }, source: envVar };
   }
   return undefined;
}
```

**规律:每个 `await` 之后加一次检查。** 因为 `await` 是唯一的让出点(P1-02 §8),取消只可能发生在那里。

### 方式二:监听事件(有资源要清理时)

```ts
function waitForPayment(orderId: string, signal?: AbortSignal): Promise<Payment> {
   return new Promise((resolve, reject) => {
      const timer = setInterval(() => { /* 轮询支付状态 */ }, 1000);

      const onAbort = () => {
         clearInterval(timer);                  // ← 清理资源
         reject(new Error("已取消"));
      };
      signal?.addEventListener("abort", onAbort, { once: true });
   });
}
```

Pi 的标准实现,[packages/ai/src/utils/provider-retry.ts:75](../packages/ai/src/utils/provider-retry.ts#L75):

```ts
function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
   return new Promise((resolve, reject) => {
      if (signal?.aborted) {                                     // ① 先检查:可能已经取消了
         reject(createAbortError());
         return;
      }

      const onAbort = () => {
         clearTimeout(timeout);                                  // ② 取消时清掉定时器
         reject(createAbortError());
      };
      const timeout = setTimeout(
         () => {
            signal?.removeEventListener("abort", onAbort);       // ③ 正常完成时摘掉监听器
            resolve();
         },
         Math.max(0, ms),
      );
      signal?.addEventListener("abort", onAbort, { once: true }); // ④ 注册
   });
}
```

**这 20 行里有四个必须做对的细节:**

- **① 进来先检查**——signal 可能在你调用前就已经 abort 了。漏了这步,已取消的操作还会跑一遍
- **② 取消时清理**——不 `clearTimeout` 的话定时器还在,虽然没人等它了但会阻止 Node 退出
- **③ 正常完成时摘监听器**——**这是最容易漏的**。一个长生命周期的 signal 上挂了几千个没摘掉的监听器,就是内存泄漏
- **④ `{ once: true }`**——触发一次后自动移除,是对 ③ 的保险

**为什么 Pi 要自己写这个?** 注释说得很直白:

> Their built-in retry timers **ignore the request AbortSignal**, so callers must invoke the SDK with `maxRetries: 0` and wrap the request with this helper.

OpenAI/Anthropic 官方 SDK 自带重试,但退避 `sleep` 不响应取消。用户按 Ctrl+C,程序还傻等 8 秒。所以 Pi 关掉 SDK 重试,自己实现了一个可取消版本。

### 方式三:直接传给原生 API(最省事)

现代 Web/Node API 都原生支持 `signal`:

```ts
await fetch(url, { signal });                        // HTTP 请求
await readFile(path, { signal });                    // 文件读取
await setTimeout(1000, undefined, { signal });       // node:timers/promises
new EventTarget().addEventListener("x", fn, { signal });  // 监听器随 signal 自动移除
```

**最后一个用法很妙**:把 `signal` 传给 `addEventListener` 的第三个参数,取消时监听器会**自动移除**,不用手动 `removeEventListener`。

---

## 3. 三个静态方法(Node 18+ / 现代浏览器)

```ts
AbortSignal.timeout(5000)          // 5 秒后自动取消的 signal
AbortSignal.abort()                // 一个"已经取消"的 signal(测试有用)
AbortSignal.any([s1, s2, s3])      // 任意一个取消,结果就取消
```

**`AbortSignal.any` 是组合取消源的标准手段。** Pi 大量使用:

```ts
// packages/ai/src/auth/oauth/anthropic.ts:178 —— 调用方取消 或 30 秒超时
signal: AbortSignal.any([signal, AbortSignal.timeout(30_000)]),

// packages/ai/src/auth/resolve.ts:149 —— OAuth 刷新加超时
const refreshSignal = AbortSignal.any([signal, AbortSignal.timeout(DEFAULT_OAUTH_REFRESH_TIMEOUT_MS)]);
```

一个更有意思的场景,[packages/ai/src/models.ts:400](../packages/ai/src/models.ts#L400):

```ts
const { generation, controller } = this.beginProviderRefresh(provider.id);
const signal = AbortSignal.any([callerSignal, controller.signal]);
```

**两个取消源**:
- `callerSignal` —— 用户取消了整个操作
- `controller.signal` —— **有更新的一次刷新把这次顶掉了**(`supersedeProviderRefresh` 会 abort 掉旧的)

第二种叫 **supersede(取代)模式**:用户快速切换模型时,前一次模型列表刷新还没回来,新的又发起了。旧的结果已经没用了,直接取消,避免"旧响应覆盖新响应"的经典竞态。

**这个模式在电商前端也很常见**:搜索框输入时,前一次搜索请求要被后一次取代。

---

## 4. Pi 实战:Agent 的取消是怎么串起来的

### 4.1 一次运行一个 controller

[packages/agent/src/agent.ts:486](../packages/agent/src/agent.ts#L486):

```ts
private async runWithLifecycle(executor: (signal: AbortSignal) => Promise<void>): Promise<void> {
   if (this.activeRun) {
      throw new Error("Agent is already processing.");
   }

   const abortController = new AbortController();          // ← 每次 run 一个新的
   let resolvePromise = () => {};
   const promise = new Promise<void>((resolve) => { resolvePromise = resolve; });
   this.activeRun = { promise, resolve: resolvePromise, abortController };

   this._state.isStreaming = true;
   try {
      await executor(abortController.signal);              // ← signal 交给整个执行链
   } catch (error) {
      await this.handleRunFailure(error, abortController.signal.aborted);
      // ...
   }
}
```

对外暴露的接口([agent.ts:314](../packages/agent/src/agent.ts#L314)):

```ts
/** Active abort signal for the current run, if any. */
get signal(): AbortSignal | undefined {
   return this.activeRun?.abortController.signal;
}

/** Abort the current run, if one is active. */
abort(): void {
   this.activeRun?.abortController.abort();
}
```

**设计要点:controller 是私有的,外界只能通过 `abort()` 方法触发,只能通过 `signal` getter 观察。** 封装得很干净。

注意 `handleRunFailure(error, abortController.signal.aborted)` 传了 `aborted` 标志——**因为"取消导致的失败"和"真的出错了"要区别对待**:前者是用户意图,不该报错;后者要显示错误。

### 4.2 信号穿透整条链路

一个 signal 从 `Agent` 一路传到最深处:

```
Agent.prompt()
  └─ runWithLifecycle()  ← 创建 AbortController
      └─ agentLoop(..., signal, ...)
          └─ runLoop(..., signal, ...)
              ├─ streamAssistantResponse(..., signal, ...)
              │     └─ streamFunction(model, ctx, { ...config, signal })   ← 传给 ai 层
              │           └─ fetch(url, { signal })                         ← 最终到 HTTP
              │
              └─ executeToolCalls(..., signal, ...)
                    ├─ beforeToolCall({ ..., signal })                      ← 钩子也能收到
                    ├─ tool.execute(id, params, signal, onUpdate)           ← 工具收到
                    │     └─ spawn(cmd, { signal })                         ← shell 子进程
                    └─ afterToolCall({ ..., signal })
```

**每一层都显式地把 signal 往下传。** 没有任何"隐式上下文"(Java 的 `ThreadLocal` / Spring 的 `RequestContextHolder` 那种)。

**这很啰嗦,但是有意的**:JS 没有线程,`ThreadLocal` 那套用不了;而且显式传递让"哪些操作可取消"一目了然。

循环里的检查点([agent-loop.ts](../packages/agent/src/agent-loop.ts)):

```ts
// 预检之后
if (signal?.aborted) {
   return { kind: "immediate", result: createErrorToolResult("Operation aborted"), isError: true };
}

// 每个串行工具执行完之后
if (signal?.aborted) break;
```

注意**取消不是抛异常,而是变成一个 `isError` 的工具结果**。为什么?因为这条结果**要写进对话历史**——模型需要知道"这个工具被取消了",否则下一轮它会困惑于为什么没有结果。

**这是个很好的细节:取消也是一种业务状态,不只是控制流。**

---

## 5. ⚠️ 取消 ≠ 停止

**这是最容易误解的一点。**

`abort()` 只是"发了个信号"。**没有任何东西被强制终止。**

```ts
async function slowTask(signal: AbortSignal) {
   await heavyComputation();       // ← 不检查 signal,取消了它也照跑完
   await anotherStep();            // ← 这个也是
}
```

调用 `controller.abort()` 之后,`slowTask` 会**完整跑完**,因为它压根没检查。

### 后果一:`Promise.all` 的僵尸任务

```ts
const results = await Promise.all([taskA(), taskB(), taskC()]);
// taskB 失败 → Promise.all 立刻 reject
// 但 taskA 和 taskC 【还在跑】,只是没人要它们的结果了
```

如果 taskA 有副作用(写库、扣款),它照样会执行。**这就是为什么 Pi 到处传 signal**——只有传进去并被检查,才是真正的取消。

### 后果二:Pi 里的工具不会被强杀

从 P0 阶段的架构报告里有一句关键描述:

> Aborts do **not** cancel in-flight tool promises — they surface as `stopReason: "aborted"` and the loop returns.

意思是:你按 Ctrl+C 时,**正在执行的工具不会被强制中断**。循环会立刻返回,UI 立刻响应,但那个 `bash` 命令可能还在后台跑。

真正杀掉子进程要靠工具自己实现——Pi 的 `NodeExecutionEnv`([agent/src/harness/env/nodejs.ts](../packages/agent/src/harness/env/nodejs.ts))里就做了**进程树杀死**(process-tree kill),因为 `bash -c "npm test"` 会派生一堆子进程,只杀父进程是不够的。

**电商类比**:取消订单 ≠ 停止已经发出的物流。你得额外调用物流公司的拦截接口。

### 后果三:被放弃的 Promise 仍需接住

```ts
// packages/ai/src/utils/abort.ts:17
export function raceWithAbortSignal<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
   if (signal.aborted) {
      void operation.catch(() => {});          // ← 关键这行
      return Promise.reject(abortReason(signal));
   }
   // ...
}
```

注释解释得很清楚:

> Stop waiting for an operation when its signal aborts **while continuing to observe the abandoned promise so a later rejection is always handled.**

**我们不等它了,但它还在跑,将来可能失败。** 如果不接住那个 rejection,Node 会因为 `UnhandledPromiseRejection` 直接退出进程(P1-02 §10.2)。

`void x.catch(() => {})` 的意思是:"我知道它可能失败,我明确表示不关心"。

---

## 6. Pi 的完整版 race 实现

[packages/ai/src/utils/abort.ts](../packages/ai/src/utils/abort.ts) 全文值得读:

```ts
function abortReason(signal: AbortSignal): unknown {
   if (signal.reason !== undefined) return signal.reason;
   const error = new Error("The operation was aborted");
   error.name = "AbortError";                  // ← 约定的错误名
   return error;
}

/** Create an operation-local signal for public APIs whose signal is optional. */
export function operationSignal(signal?: AbortSignal): AbortSignal {
   return signal ?? new AbortController().signal;    // ← 没传就造一个永不取消的
}

export function raceWithAbortSignal<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
   if (signal.aborted) {
      void operation.catch(() => {});
      return Promise.reject(abortReason(signal));
   }

   return new Promise<T>((resolve, reject) => {
      let settled = false;                                  // ① 防止重复结算
      const cleanup = () => signal.removeEventListener("abort", onAbort);
      const onAbort = () => {
         if (settled) return;
         settled = true;
         cleanup();
         reject(abortReason(signal));
      };

      signal.addEventListener("abort", onAbort, { once: true });
      void operation.then(
         (value) => {
            if (settled) return;
            settled = true;
            cleanup();                                       // ② 成功也要摘监听器
            resolve(value);
         },
         (error: unknown) => {
            if (settled) return;
            settled = true;
            cleanup();
            reject(error);
         },
      );
      if (signal.aborted) onAbort();                          // ③ 兜底:注册期间被取消了
   });
}
```

**三个防御性细节:**

- **① `settled` 标志**——虽然 Promise 本身保证只结算一次,但 `cleanup()` 不能调两次,而且逻辑上要明确
- **② 成功路径也 cleanup**——不摘监听器就是泄漏
- **③ 最后再检查一次**——在你 `addEventListener` 和 `operation.then` 这段同步代码执行期间,理论上 signal 可能已经 abort。这是一种偏执但正确的写法

**`operationSignal(signal?)` 这个小工具也很实用**:很多公开 API 的 `signal` 是可选的,内部又希望统一按"一定有 signal"来写。它就返回一个永远不会取消的 signal 兜底。

**`error.name = "AbortError"` 是个约定**:整个 JS 生态(`fetch`、Node API)都用这个名字表示"是取消,不是真的出错"。判断方式:

```ts
try {
   await fetch(url, { signal });
} catch (e) {
   if (e instanceof Error && e.name === "AbortError") {
      // 用户取消,静默处理
   } else {
      // 真的出错了,该报错报错
   }
}
```

---

## 7. 电商实战:给批量操作加取消

综合练习——一个可取消的批量发货:

```ts
async function batchShip(
   orderIds: string[],
   signal?: AbortSignal,
   onProgress?: (done: number, total: number) => void,
): Promise<{ shipped: string[]; failed: string[]; cancelled: boolean }> {
   const shipped: string[] = [];
   const failed: string[] = [];

   for (const [i, id] of orderIds.entries()) {
      // ① 每轮开头检查
      if (signal?.aborted) {
         return { shipped, failed, cancelled: true };   // 返回已完成的部分
      }

      try {
         // ② 把 signal 传给底层 HTTP
         await shipApi.ship(id, { signal });
         shipped.push(id);
      } catch (e) {
         // ③ 区分"取消"和"真失败"
         if (e instanceof Error && e.name === "AbortError") {
            return { shipped, failed, cancelled: true };
         }
         failed.push(id);
      }

      onProgress?.(i + 1, orderIds.length);
   }

   return { shipped, failed, cancelled: false };
}

// 用法:加上 10 秒超时
const controller = new AbortController();
const result = await batchShip(ids, AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]));
```

**四个关键点**(全部来自前面讲的模式):
1. 循环里检查
2. signal 传给底层
3. 用 `name === "AbortError"` 区分取消和错误
4. **取消不是抛异常,而是返回"部分结果 + cancelled 标志"**——因为已经发货的订单是既成事实,调用方需要知道

第 4 点就是 Pi 把取消变成 `isError` 工具结果的同一个思路:**取消是业务状态,不只是控制流**。

---

## 8. 常见坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 收了 signal 但从不检查 | `abort()` 毫无效果 | 每个 `await` 后加检查 |
| 只在开头检查一次 | 长循环取消不了 | 循环里每轮都检查 |
| 忘了正常完成时摘监听器 | 内存泄漏,signal 上挂几千个监听器 | `removeEventListener` 或 `{ once: true }` |
| 进来不检查 `signal.aborted` | 已取消的操作还跑一遍 | 函数开头先检查 |
| 以为 `abort()` 会强制停止 | 任务还在跑,副作用照样发生 | 理解协作式取消;子进程要单独杀 |
| 被放弃的 Promise 没接住 | 进程因 UnhandledRejection 退出 | `void p.catch(() => {})` |
| 把取消当成错误报给用户 | 用户主动取消却弹错误框 | 用 `e.name === "AbortError"` 区分 |
| 多个取消源手写组合逻辑 | 代码冗长易错 | 用 `AbortSignal.any([...])` |
| 想加超时手写 setTimeout | 忘记清理 | 用 `AbortSignal.timeout(ms)` |
| 复用同一个 controller | 第二次 abort 无效(已经 aborted 了) | **controller 是一次性的**,每次操作新建 |

**最后一条特别重要**:`AbortController` 用过一次就废了。Pi 每次 `run` 都 `new AbortController()`,就是这个原因。

---

## 9. 动手练习

**练习 1(基础)**:实现 §7 的 `batchShip`,用 `setTimeout` 模拟发货接口。验证:
- 3 秒后 `abort()`,看返回的 `shipped` 是不是部分结果
- `cancelled` 标志对不对

**练习 2(可取消 sleep)**:不看 Pi 的代码,自己实现 `abortableSleep(ms, signal)`。写完对照 [provider-retry.ts:75](../packages/ai/src/utils/provider-retry.ts#L75),检查你有没有漏掉那四个细节(进来检查 / 取消清理 / 完成摘监听 / once)。

**练习 3(内存泄漏)**:写一个循环,给同一个 signal 注册 10000 个不摘除的监听器,用 `process.memoryUsage()` 观察内存。然后加上 `{ once: true }` 再测一遍。

**练习 4(supersede 模式)**:实现一个搜索函数,快速调用三次时,前两次自动被取消:

```ts
class SearchService {
   search(keyword: string): Promise<Order[]>   // 内部管理 controller,新的取消旧的
}
```

参考 Pi 的 `supersedeProviderRefresh`([models.ts:320](../packages/ai/src/models.ts#L320))。

**练习 5(组合信号)**:用 `AbortSignal.any` 实现"用户取消 或 超时 或 被新请求取代",三个源任意一个触发都停止。

**练习 6(读 Pi 源码)**:完整读 [packages/ai/src/utils/abort.ts](../packages/ai/src/utils/abort.ts):
- `operationSignal` 为什么需要?不用它会怎样?
- `raceWithAbortSignal` 里的 `settled` 标志能不能去掉?会有什么问题?
- 最后那行 `if (signal.aborted) onAbort();` 什么时候会真的触发?

**练习 7(读 Pi 源码)**:在 [agent-loop.ts](../packages/agent/src/agent-loop.ts) 里搜索所有 `signal` 出现的位置,画出信号从 `Agent.abort()` 到 `tool.execute` 的完整传递路径。数一数中间经过了几层。

**练习 8(实验)**:跑 `./pi-test.sh`,发一个会让它跑很久的任务(比如"读取所有文件并总结"),然后按 Ctrl+C。观察:
- UI 多久响应?
- 会话文件里那条被取消的记录长什么样?
- 如果当时正在跑 bash 命令,那个进程真的被杀了吗?(用 `ps` 看)

---

## 10. 自测清单

1. `AbortController` 和 `AbortSignal` 分别给谁用?为什么要分开?
2. 响应取消的三种方式是什么?各适用于什么场景?
3. `signal.throwIfAborted()` 和 `if (signal.aborted) throw ...` 有区别吗?
4. 检查点应该放在哪里?为什么是"每个 await 之后"?
5. `abortableSleep` 里有哪四个必须做对的细节?漏掉每一个分别会怎样?
6. Pi 为什么要自己实现重试而不用 SDK 自带的?
7. `AbortSignal.any` 和 `AbortSignal.timeout` 分别解决什么问题?
8. 什么是 supersede 模式?电商里哪里会用到?
9. `abort()` 会强制停止正在跑的任务吗?为什么?
10. `Promise.all` 中一个失败后,其他任务会停吗?怎么才能真停?
11. 为什么被放弃的 Promise 还要 `.catch(() => {})`?
12. Pi 里工具被取消时,为什么变成 `isError` 的工具结果而不是抛异常?
13. `error.name === "AbortError"` 这个约定有什么用?
14. `AbortController` 能复用吗?Pi 是怎么处理的?

---

**上一篇**:[P1-06 · AsyncIterable 与 for await](P1-06-异步迭代.md)
**下一篇**:[P1-08 · unknown 与 any](P1-08-unknown与any.md) —— 类型安全的边界在哪
