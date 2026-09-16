# P1-02 · async / await / Promise

> 目标:建立单线程事件循环的心智模型,写出正确且不慢的异步代码
> 前置:[P1-00](P1-00-JS-TS语法热身.md)、[P1-01](P1-01-ESM模块系统.md)
> 读完你应该能:看出一段异步代码是"串行"还是"并发",并解释 Pi 的工具并行执行为什么要先串行预检

---

## 0. 一句话总结

**Java 用"多线程 + 阻塞"实现并发,JS 用"单线程 + 不阻塞"实现并发。**

只有一个线程在跑你的代码。这句话是理解一切的钥匙——也是最反直觉的地方,因为 Node 明明能同时处理几千个请求。

---

## 1. 心智模型:从"线程池"切换到"事件循环"

### Java 的模型

```java
// SpringBoot 里,每个请求一个线程
@GetMapping("/order/{id}")
public Order getOrder(@PathVariable String id) {
    Order order = orderRepo.findById(id);      // 线程在这里【阻塞】等 DB
    User user = userClient.get(order.userId);  // 线程在这里【阻塞】等 HTTP
    return order;
}
```

并发靠什么?**靠线程数**。Tomcat 默认 200 个线程,就能同时处理 200 个请求。线程阻塞时,操作系统把它挂起,调度别的线程上 CPU。

代价:每个线程 ~1MB 栈内存,上下文切换有开销,一万并发就要一万线程(所以才有了 Netty、虚拟线程)。

### JS 的模型

```ts
// Node 里,所有请求共用一个线程
async function getOrder(id: string): Promise<Order> {
   const order = await orderRepo.findById(id);      // 不阻塞!线程去干别的了
   const user = await userClient.get(order.userId); // 不阻塞!
   return order;
}
```

**关键**:`await` 不是"阻塞等待",而是:

1. 把 I/O 请求交给操作系统(或线程池)
2. **把当前函数"挂起",记住执行到哪一行了**
3. **线程立刻回到事件循环,去处理别的任务**
4. I/O 完成后,把"继续执行这个函数"塞进队列
5. 事件循环轮到它时,从挂起的那一行继续

所以一个线程能同时"进行中"几千个请求——因为它们绝大部分时间都在等 I/O,而等待不占线程。

**类比**:Java 的线程像"一个服务员盯一桌客人,客人点完菜服务员就站着等厨房出菜";Node 像"一个服务员管所有桌,下单后立刻去服务下一桌,菜好了再回来上菜"。

### 一张对照表

| | Java | JS/Node |
|---|---|---|
| 并发单位 | 线程 | 回调/Promise |
| 等 I/O 时 | 线程阻塞挂起 | 函数挂起,**线程继续干活** |
| 提升并发靠 | 加线程 | 不用加,单线程就够 |
| CPU 密集任务 | 多线程并行 | ❌ **会卡死整个进程**(见 §9) |
| 竞态条件 | 有,靠 `synchronized` | **也有**,但不需要锁(见 §8) |
| 线程安全 | 需要关心 | 不需要,但**状态一致性需要关心** |

---

## 2. Promise:异步结果的容器

`Promise<T>` ≈ Java 的 `CompletableFuture<T>`。它有三个状态:

```
pending(进行中) ──┬──→ fulfilled(成功,带一个值 T)
                  └──→ rejected(失败,带一个错误)
```

**一旦离开 pending 就永久固定**,不能再变。

### 2.1 创建 Promise

大多数时候你不需要手动创建——异步 API 直接返回 Promise。但理解构造函数很重要:

```ts
const p = new Promise<Order>((resolve, reject) => {
   // 这个函数【立刻同步执行】
   setTimeout(() => {
      if (Math.random() > 0.5) {
         resolve(order);        // 成功
      } else {
         reject(new Error("超时"));   // 失败
      }
   }, 1000);
});
```

**最常见的用途:把"回调风格"的老 API 包装成 Promise。** 电商例子:

```ts
// 老式回调 API
function queryOrderLegacy(id: string, callback: (err: Error | null, order?: Order) => void) { }

// 包装成 Promise
function queryOrder(id: string): Promise<Order> {
   return new Promise((resolve, reject) => {
      queryOrderLegacy(id, (err, order) => {
         if (err) reject(err);
         else resolve(order!);
      });
   });
}
```

Pi 里有个教科书级的例子——把 `setTimeout` 包装成**可取消的 sleep**([packages/ai/src/utils/provider-retry.ts:75](../packages/ai/src/utils/provider-retry.ts#L75)):

```ts
function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
   return new Promise((resolve, reject) => {
      if (signal?.aborted) {
         reject(createAbortError());
         return;
      }

      const onAbort = () => {
         clearTimeout(timeout);          // 取消了就清掉定时器
         reject(createAbortError());
      };
      const timeout = setTimeout(
         () => {
            signal?.removeEventListener("abort", onAbort);   // 正常完成,摘掉监听器
            resolve();
         },
         Math.max(0, ms),
      );
      signal?.addEventListener("abort", onAbort, { once: true });
   });
}
```

为什么要自己写?注释解释了:

> Their built-in retry timers **ignore the request AbortSignal**, so callers must invoke the SDK with `maxRetries: 0` and wrap the request with this helper.

OpenAI/Anthropic 官方 SDK 自带重试,但它的退避 `sleep` **不响应取消**。用户按了 Ctrl+C,程序还要傻等 8 秒。所以 Pi 关掉 SDK 重试,自己实现了一个可取消版本。

**这段代码值得你逐行读三遍**,它同时演示了:Promise 包装回调、事件监听器的注册与清理、以及取消语义(下一篇 P1-07 详讲)。

### 2.2 then / catch / finally

```ts
queryOrder("O1001")
   .then(order => order.amountCents)        // 转换值,返回新 Promise
   .then(cents => console.log(cents))
   .catch(err => console.error(err))        // 捕获链条上任意一环的错误
   .finally(() => console.log("完成"));      // 无论成败都执行
```

对应 Java:`.thenApply()` / `.exceptionally()` / `.whenComplete()`。

**但在 Pi 里你几乎看不到 `.then()` 链**,因为 `async/await` 更好读。`.then()` 主要用在一个场景:**"发射后不管"**。

看 [packages/ai/src/api/lazy.ts:46](../packages/ai/src/api/lazy.ts#L46):

```ts
export function lazyStream(
   model: Model<Api>,
   setup: () => Promise<AsyncIterable<AssistantMessageEvent>>,
): AssistantMessageEventStream {
   const outer = new AssistantMessageEventStream();

   setup()                                        // ← 注意:没有 await
      .then((inner) => forwardStream(outer, inner))
      .catch((error) => {
         const message = createSetupErrorMessage(model, error);
         outer.push({ type: "error", reason: "error", error: message });
         outer.end(message);
      });

   return outer;                                  // ← 立刻【同步】返回
}
```

**为什么不 await?** 因为函数要**同步返回流对象**,而加载和认证在背后跑。如果写成 `async function`,返回的就是 `Promise<Stream>`,调用方就得 `await` 了。

这个模式在 Pi 里很关键:**流对象先给你,内容慢慢来,出错就变成流里的一个 error 事件。**

---

## 3. async / await:Promise 的语法糖

```ts
// 这两段完全等价
function a(): Promise<number> {
   return queryOrder("O1").then(o => o.amountCents);
}

async function b(): Promise<number> {
   const o = await queryOrder("O1");
   return o.amountCents;
}
```

两条规则:

1. **`async` 函数的返回值自动包成 Promise**。`return 5` 实际返回 `Promise<5>`。
2. **`await` 只能在 `async` 函数里用**(顶层例外,见下)。

**顶层 await**:ESM 模块里可以直接在文件顶层 `await`,不需要包函数。Pi 的 SDK 示例就是这么写的:

```ts
// packages/coding-agent/examples/sdk/01-minimal.ts
const { session } = await createAgentSession();    // 顶层 await,合法
```

**⚠️ 一个高频错误:忘了 await**

```ts
async function pay(orderId: string) {
   const order = queryOrder(orderId);     // ❌ 忘了 await
   console.log(order.amountCents);        // ❌ order 是 Promise,没有 amountCents
}
```

TS 能帮你抓到大部分(类型是 `Promise<Order>` 而不是 `Order`),但如果你只是调用一个返回 `Promise<void>` 的函数忘了 await,**编译器不会报错,程序会静默地不按顺序执行**。这是最难查的 bug 之一。

Pi 的做法是遇到"故意不 await"时用 `void` 标记出来:

```ts
// packages/ai/src/utils/abort.ts:19
void operation.catch(() => {});    // 明确表示:我知道这是 Promise,我故意不等
```

看到 `void xxx()` 就是"我是故意的",而不是忘了。

---

## 4. ⚠️ 串行 vs 并发:最重要的一节

这是 Java 转 JS 最容易写出性能问题的地方。

### 电商场景:订单详情页要拿三份数据

```ts
// ❌ 串行:总耗时 = 100 + 80 + 120 = 300ms
async function getOrderPageSlow(orderId: string) {
   const order = await fetchOrder(orderId);        // 等 100ms
   const user = await fetchUser(orderId);          // 再等 80ms
   const logistics = await fetchLogistics(orderId);// 再等 120ms
   return { order, user, logistics };
}
```

三个请求**互不依赖**,却排队执行了。改成并发:

```ts
// ✅ 并发:总耗时 = max(100, 80, 120) = 120ms
async function getOrderPageFast(orderId: string) {
   const [order, user, logistics] = await Promise.all([
      fetchOrder(orderId),        // 三个请求【同时】发出
      fetchUser(orderId),
      fetchLogistics(orderId),
   ]);
   return { order, user, logistics };
}
```

**关键理解:Promise 在创建的那一刻就开始执行了,`await` 只是"等它完成"。**

```ts
const p1 = fetchOrder(id);      // ← 请求已经发出去了
const p2 = fetchUser(id);       // ← 这个也发出去了,两个在并行
const order = await p1;         // 只是在这里等结果
const user = await p2;          // p2 可能早就好了
```

所以下面这两种写法**都是并发的**:

```ts
// 写法 A
const [a, b] = await Promise.all([fetchA(), fetchB()]);

// 写法 B(等价)
const pa = fetchA();
const pb = fetchB();
const a = await pa;
const b = await pb;
```

**什么时候必须串行?后一个依赖前一个的结果:**

```ts
const order = await fetchOrder(orderId);
const user = await fetchUser(order.userId);    // ← 必须先有 order 才知道 userId
```

### 循环里的陷阱

```ts
// ❌ 串行:100 个订单,每个 50ms → 5 秒
for (const id of orderIds) {
   const order = await fetchOrder(id);
   results.push(order);
}

// ✅ 并发:100 个订单同时发 → 50ms
const results = await Promise.all(orderIds.map(id => fetchOrder(id)));
```

**但要小心:100 个并发请求可能打垮下游。** 生产环境要限流(分批,或用并发控制库)。Pi 就有这个考虑——它的工具执行虽然并行,但底层的 API 调用是受控的。

⚠️ **`forEach` 不支持 async**,这是个经典陷阱:

```ts
// ❌ 完全不工作:forEach 不会等 async 回调
orderIds.forEach(async (id) => {
   await fetchOrder(id);
});
console.log("完成");    // 会立刻打印,此时一个请求都没完成

// ✅ 用 for...of(串行)或 Promise.all + map(并发)
```

### Promise 的四个组合器

| 方法 | 行为 | 什么时候用 |
|---|---|---|
| `Promise.all` | 全部成功才成功;**任一失败立刻失败** | 都必须成功(取订单详情) |
| `Promise.allSettled` | **永不失败**,返回每个的成败状态 | 部分失败可接受(批量推送通知) |
| `Promise.race` | 第一个**完成的**(不管成败)胜出 | 超时控制 |
| `Promise.any` | 第一个**成功的**胜出 | 多个镜像源取最快的 |

```ts
// allSettled:批量发短信,失败的记下来但不中断
const results = await Promise.allSettled(users.map(u => sendSms(u)));
const failed = results.filter(r => r.status === "rejected");

// race:给请求加超时
const order = await Promise.race([
   fetchOrder(id),
   new Promise<never>((_, rej) => setTimeout(() => rej(new Error("超时")), 3000)),
]);
```

⚠️ **`Promise.all` 的"快速失败"有个副作用**:一个失败了,其他 Promise **不会被取消**,它们还在跑,只是结果被丢弃了。如果它们有副作用(写库),就会出问题。要真正取消得用 `AbortSignal`(P1-07)。

---

## 5. Pi 实战:工具并行执行

现在来看 Pi 里最能体现这些概念的一段代码——[packages/agent/src/agent-loop.ts:489](../packages/agent/src/agent-loop.ts#L489) 的 `executeToolCallsParallel`。

**背景**:模型一次可能要求调用多个工具(比如同时读三个文件)。这些能不能并行?

```ts
async function executeToolCallsParallel(...): Promise<ExecutedToolCallBatch> {
   const finalizedCalls: FinalizedToolCallEntry[] = [];

   // ① 第一阶段:【串行】预检每一个工具调用
   for (const toolCall of toolCalls) {
      await emit({ type: "tool_execution_start", ... });

      const preparation = await prepareToolCall(currentContext, assistantMessage, toolCall, config, signal);

      if (preparation.kind === "immediate") {
         // 参数校验失败 / 被 beforeToolCall 拦截 → 直接出结果,不用执行
         finalizedCalls.push(finalized);
         continue;
      }

      // ② 通过预检的,包成【还没执行的函数】(thunk),先不调用
      finalizedCalls.push(async () => {
         const executed = await executePreparedToolCall(preparation, signal, emit);
         const finalized = await finalizeExecutedToolCall(...);
         await emitToolExecutionEnd(finalized, emit);
         return finalized;
      });
   }

   // ③ 第二阶段:【并发】执行所有 thunk
   const orderedFinalizedCalls = await Promise.all(
      finalizedCalls.map((entry) => (typeof entry === "function" ? entry() : Promise.resolve(entry))),
   );

   // ④ 结果按【模型输出的原始顺序】生成消息
   const messages: ToolResultMessage[] = [];
   for (const finalized of orderedFinalizedCalls) {
      const toolResultMessage = createToolResultMessage(finalized);
      await emitToolResultMessage(toolResultMessage, emit);
      messages.push(toolResultMessage);
   }

   return { messages, terminate: shouldTerminateToolBatch(orderedFinalizedCalls) };
}
```

**这段代码里有四个值得学的设计决策:**

**① 为什么预检要串行?**
`prepareToolCall` 里会调用 `beforeToolCall` 钩子——那是权限系统的挂载点。如果并行预检,弹给用户的确认框顺序就是乱的,而且钩子看到的状态不确定。**串行保证了钩子看到的顺序 = 模型输出的顺序。**

**② 为什么用 thunk(`async () => {...}`)而不是直接调用?**

这是个关键技巧。回忆 §4:**Promise 一创建就开始跑**。如果在循环里直接写 `executePreparedToolCall(...)`,它当场就执行了,那第一阶段就不是串行的了。

包成函数就"冻住"了——函数不调用就不执行。等第 ③ 步 `.map(entry => entry())` 才一起点火。

**thunk 是控制"何时开始"的标准手法**,值得记住。

**③ `Promise.all` + `map` 的混合处理**

```ts
finalizedCalls.map((entry) => (typeof entry === "function" ? entry() : Promise.resolve(entry)))
```

数组里混着两种东西:已经出结果的(预检失败的)和待执行的函数。`Promise.resolve(x)` 把普通值包成 Promise,这样 `Promise.all` 能统一处理。

**④ 完成顺序 ≠ 结果顺序**

工具**按完成先后**发 `tool_execution_end` 事件(UI 上谁先好谁先显示),但**最终消息按模型输出顺序**排列。因为 `Promise.all` 保证返回数组的顺序和输入数组一致,和完成顺序无关。

这个区分很重要:**UI 要实时性,上下文要确定性。**

对比一下串行版本(`executeToolCallsSequential`,同文件 :433),它就是简单的 `for` + `await`。什么时候用串行?`AgentTool` 上有个 `executionMode` 字段:

```ts
// packages/agent/src/types.ts:408
executionMode?: ToolExecutionMode;   // "sequential" | "parallel"
```

只要这批里有一个工具标了 `sequential`,整批都串行执行。为什么?比如 `edit` 工具改文件,并行改同一个文件会打架。

---

## 6. Pi 实战:手动持有 resolve

再看一个 Pi 里的高级用法。[packages/ai/src/utils/event-stream.ts](../packages/ai/src/utils/event-stream.ts) 的构造函数:

```ts
export class EventStream<T, R = T> implements AsyncIterable<T> {
   private finalResultPromise: Promise<R>;
   private resolveFinalResult!: (result: R) => void;      // ← 注意这个 !

   constructor(isComplete: (event: T) => boolean, extractResult: (event: T) => R) {
      this.finalResultPromise = new Promise((resolve) => {
         this.resolveFinalResult = resolve;               // ← 把 resolve 存起来!
      });
   }

   push(event: T): void {
      if (this.isComplete(event)) {
         this.done = true;
         this.resolveFinalResult(this.extractResult(event));   // ← 在别的方法里 resolve
      }
      // ...
   }

   result(): Promise<R> {
      return this.finalResultPromise;
   }
}
```

**这个模式叫 deferred(延迟量)**:创建一个 Promise,但**把它的 `resolve` 函数存到外面**,以后在任意地方调用来完成它。

Java 对应物就是 `CompletableFuture`:

```java
CompletableFuture<Result> future = new CompletableFuture<>();
// 别处
future.complete(result);
```

JS 没有内置的 deferred,所以要用这个技巧手动实现。

`resolveFinalResult!` 后面那个 `!` 是**明确赋值断言**:告诉编译器"我知道构造函数里看起来没给它赋值,但相信我,Promise 的 executor 是同步执行的,一定赋上了"。这也印证了 §2.1 说的"executor 立刻同步执行"。

**这个 `result()` 方法的价值**:调用方既可以 `for await` 逐个消费事件,也可以 `await stream.result()` 直接等最终结果,两种消费方式并存。P1-06 会详讲。

---

## 7. 事件循环:宏任务与微任务

理解执行顺序,能解释很多"为什么日志顺序不对"。

```ts
console.log("1");

setTimeout(() => console.log("2"), 0);           // 宏任务

Promise.resolve().then(() => console.log("3"));  // 微任务

console.log("4");

// 输出:1 4 3 2
```

**规则**:

1. 先跑完所有**同步代码**(`1`、`4`)
2. 再清空**微任务队列**(Promise 回调、`queueMicrotask`)→ `3`
3. 然后取**一个宏任务**执行(`setTimeout`、I/O 回调)→ `2`
4. 每个宏任务之后,再清空一次微任务队列
5. 循环

**实用推论:微任务优先级高于宏任务。** 如果你在微任务里无限产生微任务,宏任务(包括 I/O)会被饿死。

**电商场景的实际影响**:

```ts
async function handleOrder() {
   console.log("A");
   await Promise.resolve();     // 即使立刻 resolve,后面的代码也会被推到微任务
   console.log("B");            // 这行不是同步执行的!
}

handleOrder();
console.log("C");
// 输出:A C B
```

**`await` 一定会让出控制权**,哪怕等的东西已经好了。这个特性和 §8 的竞态直接相关。

---

## 8. ⚠️ 没有锁,但仍然有竞态

很多人以为"单线程就没有并发问题",**这是错的**。

```ts
// ❌ 电商超卖 bug
let stock = 1;

async function buy(userId: string) {
   if (stock > 0) {                        // ① 检查
      await recordOrder(userId);           // ② 【让出控制权!别人插进来了】
      stock -= 1;                          // ③ 扣减
   } else {
      throw new Error("售罄");
   }
}

// 两个用户同时下单
await Promise.all([buy("张三"), buy("李四")]);
console.log(stock);    // -1  ← 超卖了!
```

**为什么?** 张三执行到 ② 时让出控制权,李四进来执行 ①——此时 `stock` 还是 1,检查通过。两人都成功,库存变成 -1。

这就是 Java 里的 **check-then-act 竞态**,只不过 JS 里"切换点"是**确定的**:只可能发生在 `await` 处。

**好消息**:JS 里没有真正的并行,所以**不需要锁**——任何不含 `await` 的连续代码块都是原子的。

**坏消息**:你必须自己审查每一个 `await`,问一句"这里让出控制权后,我依赖的状态会不会被改?"

**几种解法**:

```ts
// 解法 1:把检查和修改放在同一个同步块里(最简单)
async function buy(userId: string) {
   if (stock <= 0) throw new Error("售罄");
   stock -= 1;                      // ← 先扣,和检查之间没有 await
   try {
      await recordOrder(userId);
   } catch (e) {
      stock += 1;                   // 失败了补回来
      throw e;
   }
}

// 解法 2:串行化(Pi 用的就是这招)
```

Pi 里有个教科书级的例子:[packages/agent/src/harness/tools/file-mutation-queue.ts](../packages/agent/src/harness/tools/file-mutation-queue.ts)。

**要解决的问题**:工具是并行执行的(§5),如果模型同时要求 `edit a.ts` 和 `write a.ts`,两个操作会互相覆盖。Java 里你会 `synchronized(path.intern())` 或者上个分布式锁。JS 里的做法是**排队**:

```ts
/** Serialize file mutations targeting the same environment and canonical path. */
export async function withFileMutationQueue<T>(env: ExecutionEnv, path: string, fn: () => Promise<T>): Promise<T> {
   const state = getState(env);
   const registration = state.registration.then(async () => {
      const key = await getMutationQueueKey(env, path);            // ① 解析成规范路径当 key
      const currentQueue = state.queues.get(key) ?? Promise.resolve();   // ② 拿到这个 key 上的队尾

      let releaseNext = () => {};
      const nextQueue = new Promise<void>((resolve) => {
         releaseNext = resolve;                                    // ③ deferred!存下 resolve
      });
      const chainedQueue = currentQueue.then(() => nextQueue);     // ④ 把自己挂到队尾
      state.queues.set(key, chainedQueue);
      return { key, currentQueue, chainedQueue, releaseNext };
   });
   // ...
   const { key, currentQueue, chainedQueue, releaseNext } = await registration;
   await currentQueue;                                             // ⑤ 等前面所有人做完
   try {
      return await fn();                                           // ⑥ 轮到我了
   } finally {
      releaseNext();                                               // ⑦ 放行下一个
      if (state.queues.get(key) === chainedQueue) state.queues.delete(key);
   }
}
```

**这段代码把本篇讲的东西全用上了**:

- **③ deferred 模式**——创建 Promise 并把 `resolve` 存到外面(和 §6 的 `EventStream` 一模一样),`releaseNext()` 就是"我做完了,下一位"
- **④⑤ Promise 链当队列**——每个新任务 `.then()` 到当前队尾,天然形成 FIFO
- **⑦ `finally` 保证放行**——哪怕 `fn()` 抛异常,也必须放行,否则整条队列永久卡死
- **`WeakMap<ExecutionEnv, State>`**——按环境隔离,环境被回收时状态自动清理(Java 的 `WeakHashMap`)

**注意它锁的是"规范路径"(canonical path)而不是你传进来的字符串**——`./a.ts` 和 `/abs/path/a.ts` 和符号链接都会解析成同一个 key。这个细节 Java 里用 `File.getCanonicalPath()` 也是同样的道理。

**"不用锁,用队列"是 JS 处理串行化的标准答案**,因为单线程下队列本身就是无竞争的。

**Pi 里另一个体现**:`Agent.processEvents` 的订阅者是**按注册顺序逐个 await 的**([packages/agent/src/agent.ts:588](../packages/agent/src/agent.ts#L588)):

```ts
for (const listener of this.listeners) {
   await listener(event, signal);       // 一个一个等,不并发
}
```

为什么不 `Promise.all`?因为这样 `message_end` 事件就成了一道**屏障**——所有监听器都处理完了,才继续执行工具。UI 才能保证"消息渲染完了再显示工具调用"。**用串行换取确定的顺序,这是有意的性能取舍。**

---

## 9. ⚠️ CPU 密集任务会卡死一切

```ts
// ❌ 这会让整个 Node 进程停止响应 3 秒
function calcHugeReport(orders: Order[]) {
   for (let i = 0; i < 1e9; i++) { /* 密集计算 */ }
}
```

单线程意味着:**你的代码在跑的时候,事件循环转不动**。所有请求、定时器、I/O 回调全部堵住。

Java 里这只影响一个线程,其他 199 个照常工作。Node 里这就是全站不可用。

**解法**:
- 拆成小块,中间 `await new Promise(r => setTimeout(r, 0))` 主动让出
- 用 `worker_threads`(真正的多线程,但不共享内存)
- 交给别的服务

Pi 里用了 worker 来做图片缩放,因为那是 CPU 密集的:

```
packages/coding-agent/src/utils/image-resize-worker.ts
packages/coding-agent/src/utils/image-resize-core.ts
```

**判断标准**:纯计算超过 ~50ms 就该考虑挪走。I/O 等待多久都没关系。

---

## 10. 错误处理

### 10.1 try/catch 能抓 await 的错误

```ts
async function pay(orderId: string) {
   try {
      const order = await fetchOrder(orderId);
      await charge(order);
   } catch (error) {
      // 上面任意一个 await 的失败都会到这里
      if (error instanceof Error) console.error(error.message);
      throw error;
   } finally {
      await releaseLock(orderId);
   }
}
```

### 10.2 ⚠️ 未处理的 rejection

```ts
async function bad() {
   throw new Error("boom");
}

bad();       // ❌ 没有 await 也没有 .catch() → UnhandledPromiseRejection
             // Node 22 默认会【直接终止进程】
```

**规则:每个 Promise 要么被 await,要么有 `.catch()`。**

如果确实想"发射后不管",要显式吞掉:

```ts
void bad().catch(() => {});     // 明确表示我知道它可能失败,我不关心
```

Pi 里就是这么写的,[packages/ai/src/utils/abort.ts:19](../packages/ai/src/utils/abort.ts#L19):

```ts
export function raceWithAbortSignal<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
   if (signal.aborted) {
      void operation.catch(() => {});     // ← 被放弃的 Promise 也要接住它的失败
      return Promise.reject(abortReason(signal));
   }
   // ...
}
```

注释写得很清楚:

> Stop waiting for an operation when its signal aborts **while continuing to observe the abandoned promise so a later rejection is always handled**.

取消时我们不等它了,但它还在跑,将来可能失败。如果不接住,进程就崩了。**这是个非常容易漏的细节。**

### 10.3 Pi 的"永不抛异常"契约

Java 有 checked exception 逼你处理。JS 没有,所以 Pi 用**文档契约**代替。

`StreamFn` 的定义([packages/agent/src/types.ts:23](../packages/agent/src/types.ts#L23)):

> **must not throw**; failures must be encoded as a final `AssistantMessage` with `stopReason: "error" | "aborted"`

为什么?因为流式场景下,异常没地方抛。你已经把流对象返回给调用方了,调用方正在 `for await`,这时候底层出错——抛给谁?

所以约定:**所有失败都变成流里的一个 `error` 事件**。调用方只需要处理事件,不需要 try/catch。

同样的契约也用在 `AgentLoopConfig` 的钩子上("must not throw or reject"),因为底层循环没有 try/catch 包着它们。

**这是个重要的工程思路:当语言不提供强制机制时,用契约 + 纪律 + 代码审查来保证。**

---

## 11. 常见坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 忘了 `await` | 拿到 Promise 对象而不是值;顺序错乱 | 打开 TS 严格模式;可疑处检查类型 |
| `forEach` 里用 async | 循环不等待,立刻往下走 | 用 `for...of` 或 `Promise.all(arr.map(...))` |
| 该并发写成了串行 | 接口慢好几倍 | 无依赖的 `await` 提出来用 `Promise.all` |
| 无限并发 | 打垮下游 / 内存爆 | 分批或限流 |
| 未处理 rejection | 进程直接退出 | `await` 或 `.catch()`;故意忽略用 `void x.catch(()=>{})` |
| check-then-act 竞态 | 超卖、重复扣款 | 检查和修改之间不要有 `await`;或用队列串行化 |
| CPU 密集堵住事件循环 | 全站卡死 | worker_threads / 分片让出 |
| `Promise.all` 失败后其他没取消 | 副作用照常发生 | 用 `AbortSignal` 真正取消 |
| 以为单线程就没并发问题 | 各种状态错乱 | 审查每一个 `await` 前后的状态假设 |

---

## 12. 动手练习

**练习 1(串行 vs 并发)**:写一个模拟订单详情接口,用 `setTimeout` 假装 I/O:

```ts
const delay = (ms: number) => new Promise(r => setTimeout(r, ms));
const fetchOrder     = async () => { await delay(100); return { id: "O1", userId: "U1" }; };
const fetchUser      = async () => { await delay(80);  return { name: "张三" }; };
const fetchLogistics = async () => { await delay(120); return { status: "运输中" }; };
```

分别用串行和 `Promise.all` 实现,用 `console.time` / `console.timeEnd` 测耗时,验证 300ms vs 120ms。

**练习 2(复现竞态)**:把 §8 的超卖例子跑一遍,亲眼看到 `stock` 变成 -1。然后用两种解法各修一遍。

**练习 3(thunk)**:实现一个 `runWithLimit(tasks, limit)`,接收一组 thunk(`(() => Promise<T>)[]`),最多同时跑 `limit` 个。这个练习能让你真正理解为什么 Pi 要用 thunk 而不是直接传 Promise。

**练习 4(读 Pi 源码)**:打开 [packages/agent/src/agent-loop.ts:433](../packages/agent/src/agent-loop.ts#L433) 的 `executeToolCallsSequential`,和 :489 的并行版对比:
- 两者的事件发射顺序有什么不同?
- 为什么并行版需要 thunk,串行版不需要?
- 如果去掉并行版的第一阶段串行预检,会出什么问题?

**练习 5(deferred)**:自己实现一个 `createDeferred<T>()`,返回 `{ promise, resolve, reject }`。然后用它重写 `EventStream` 里那段构造函数,体会为什么需要 `!` 断言。

---

## 13. 自测清单

1. Java 用什么实现并发?JS 用什么?为什么 JS 单线程也能高并发?
2. `await` 是"阻塞线程"吗?它到底做了什么?
3. Promise 有几个状态?能从 fulfilled 变回 pending 吗?
4. `const p = fetch()` 这行执行后,请求发出去了吗?
5. 三个互不依赖的异步调用,怎么写才是并发?写错了会怎样?
6. `Promise.all` 和 `Promise.allSettled` 什么时候各用哪个?
7. `forEach(async ...)` 为什么不工作?
8. 输出顺序:`console.log(1); setTimeout(()=>log(2)); Promise.resolve().then(()=>log(3)); log(4)`
9. 单线程为什么还会有竞态?切换点在哪里?
10. Pi 的 `executeToolCallsParallel` 为什么第一阶段要串行?为什么要用 thunk?
11. Pi 的 `abortableSleep` 解决了什么问题?为什么不用 SDK 自带的重试?
12. `StreamFn` 为什么规定"must not throw"?失败怎么传递?
13. `void promise.catch(() => {})` 是什么意思?为什么需要它?
14. 一个耗时 3 秒的纯计算会造成什么后果?Java 里呢?

---

**上一篇**:[P1-01 · ESM 模块系统](P1-01-ESM模块系统.md)
**下一篇**:[P1-03 · 结构化类型](P1-03-结构化类型.md) —— 为什么 TS 不需要 implements
