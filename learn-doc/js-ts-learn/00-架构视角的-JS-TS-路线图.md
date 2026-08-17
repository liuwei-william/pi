# 架构视角的 JS / TS 学习路线图

> 基线：pi `v0.84.2` · commit `c7c763f5c` · 2026-08-17
> 读者：Java / SpringBoot 后端工程师，JS/TS 零基础
> 定位：这是 [00-学习路线图.md](../00-学习路线图.md) 里 **P1 阶段的展开版**。主路线图讲「学 Pi」，这份讲「学到什么程度才读得懂 Pi 的结构」。
> 不讲的：变量声明、字符串方法、数组 API、可选链这类查一次就会的语法。卡住时现查。

---

## 零、先接受六个"反直觉"

Java 的架构是**语言和框架替你锁死的**：`package` 划边界、`private` 挡访问、`implements` 建契约、Spring 容器管装配、Maven 模块管依赖方向。你写代码时不需要想"架构在哪"，因为它在编译器里。

TypeScript 反过来：**语言几乎什么都不锁**。架构存在于约定、构建配置和自定义校验脚本里。所以「学 TS 架构」的本质，是学**边界到底画在哪个文件里**。

下面六条是全部认知落差的根源，先记住，后面每一阶段都在还这笔账：

| # | Java 的世界 | JS/TS 的世界 | 后果 |
|---|---|---|---|
| 1 | 类型在运行时存在（反射、注解、`instanceof` 泛型擦除但类还在） | **类型在运行时完全不存在**，`tsc` 只是把类型删掉 | 没有反射驱动的框架，没有 `@Autowired`；外部数据必须手写运行时校验 |
| 2 | 名义类型：`implements` 才算实现 | **结构类型**：形状对得上就算实现 | 对象字面量可以直接当"Bean"，不需要类 |
| 3 | Spring 容器负责装配 | **没有容器**，依赖靠函数参数手动传 | 依赖关系全部显式写在签名里，读代码即读依赖图 |
| 4 | `package` + 访问修饰符定义可见性 | 只有"导出/不导出"，**模块边界靠 `package.json` 的 `exports` 字段** | 包的公开 API 是一段 JSON，不是一堆 `public` |
| 5 | 多线程 + 锁 | **单线程事件循环** | 没有 `synchronized`，但每个 `await` 之后状态都可能变了 |
| 6 | 分层靠 Maven 模块依赖，违反直接编译失败 | 分层靠**约定 + 自己写的检查脚本** | 想知道架构约束，得去读 `scripts/*.mjs` 和 CI |

一句话：**在 Java 里读架构你读注解，在 TS 里读架构你读 `package.json`、`tsconfig.json` 和 `index.ts`。**

---

## 一、路线总览

| 阶段 | 主题 | 天数 | 一句话目标 |
|---|---|---|---|
| **A0** | 心智转换 | 0.5 | 接受上面六条，知道 TS 不是"带类型的 Java" |
| **A1** | 模块与边界 | 2–3 | 能说出 Pi 每个包的公开 API 边界画在哪一行 |
| **A2** | 类型即接口 | 3–4 | 能用判别联合和函数类型表达抽象，而不是第一反应写 class |
| **A3** | 组装与依赖注入 | 2–3 | 能在没有容器的代码里追出完整依赖链 |
| **A4** | 异步即架构 | 2–3 | 能读懂流式 + 取消是怎么贯穿整个调用栈的 |
| **A5** | 工程治理 | 1–2 | 知道这个项目的架构约束由哪些脚本强制执行 |
| **A6** | 收口验收 | 1 | 独立画出 Pi 的分层图并解释每条边 |

**总计 12–17 天**（按每天 2–3 小时算）。比主路线图 P1 的 5–8 天长，因为那里只要求"能读懂语法"，这里要求"能评价设计"。

**贯穿始终的方法**：不写 toy 项目。每个阶段都有指定的 Pi 源文件当教材，读完能回答验收问题就过。

---

## A0 — 心智转换（0.5 天）

**做三件事**：

1. 把上面那张表抄一遍，用自己的话写「为什么 TS 没有 Spring」。
2. 跑一次 `npx tsc --noEmit` 和 `node --experimental-strip-types` 的对比，亲眼看到类型是被**删掉**的，不是被编译进去的。
3. 打开 [packages/telemetry/src/index.ts](../../packages/telemetry/src/index.ts)，357 行，**依赖为零**。看 `TelemetryContext` / `TelemetrySpan` 两个接口 —— 这就是一个纯端口定义，等价于你写一个只有 interface 的 `xxx-api` Maven 模块。

**验收**：能解释为什么 `telemetry` 包 `dependencies` 是空对象，却被 `ai` 和 `agent` 依赖。

---

## A1 — 模块与边界（2–3 天）

> 📖 **本阶段有独立详解文档：[A1-模块与边界.md](./A1-模块与边界.md)**（含电商完整示例、Java/Spring 逐条对照、6 道练习）。下面是提纲。

这是整个路线图**最重要**的一段。TS 项目的架构 90% 体现在模块边界上。

### 1.1 ESM：路径即身份

- `import` / `export`，没有 classpath，**文件路径就是模块 ID**。
- Pi 用 `"type": "module"`（纯 ESM），并且导入写**显式 `.ts` 后缀**：`import { x } from "./types.ts"`。这是 Node 原生类型剥离模式的要求，也是为什么项目里有一个脚本专门禁止写 `.js` 后缀（下面 A5 会讲）。
- 模块是**单例**：同一个路径无论被 import 多少次，模块顶层代码只执行一次。这天然等价于 Spring 的 singleton scope —— 所以 Pi 里的"注册表"就是一个模块级的 `Map`，不需要容器。
- `import type { X }` 是纯类型导入，编译后完全消失，**不产生运行时依赖**。这是切断循环依赖的常用手法，读代码时要能一眼分辨。

### 1.2 包的公开 API = `package.json` 的 `exports`

这是 Java 工程师最容易忽略的一处。看 [packages/agent/package.json](../../packages/agent/package.json)：

```json
"exports": {
  ".":                  { "types": "./dist/index.d.ts",    "import": "./dist/index.js" },
  "./node":             { "types": "./dist/node.d.ts",     "import": "./dist/node.js" },
  "./session/testing":  { "types": "./dist/harness/session/testing/index.d.ts", ... },
  "./package.json":     "./package.json"
}
```

含义：**`dist` 里其他任何文件，外部都 import 不到**。这就是 Java 9 `module-info.java` 的 `exports` 或 OSGi 的 `Export-Package`。

四个入口分别是：主 API、Node 专属 API（有原生依赖，浏览器不能用）、测试工具、以及自身元信息。**「按运行环境切分入口」是 JS 生态特有的架构手段** —— 因为同一份代码要跑在 Node、浏览器、Bun 上。

对比 [packages/ai/package.json](../../packages/ai/package.json)，它开了 `"./providers/*"` 和 `"./api/*"` 两个**通配入口**，意思是「这两个目录整体对外开放，随便按需引」。而 `packages/telemetry` 只开了两个入口。**入口数量和形状 = 这个包想被怎么用**，读包先读这里。

### 1.3 `index.ts`：门面 / Barrel

每个包的 `src/index.ts` 是手写的公开 API 清单。数据：

```
telemetry/src/index.ts      357 行   （接口定义直接写在这）
agent/src/index.ts          145 行
tui/src/index.ts            147 行
coding-agent/src/index.ts   408 行
ai/src/index.ts              47 行
protocol/src/index.ts         4 行
```

`ai` 只有 47 行而 `coding-agent` 有 408 行，说明前者暴露面窄、后者是产品层什么都要暴露。**这个数字本身就是架构信号。**

Java 类比：`index.ts` ≈ 一个只有 `public static` 重导出的 Facade 类 + `package-info`。

### 1.4 多模块：npm workspaces + tsconfig paths

- 根 [package.json](../../package.json) 的 `workspaces: ["packages/*", ...]` ≈ Maven 的 `<modules>`。
- 根 [tsconfig.json](../../tsconfig.json) 的 `paths` 把 `@earendil-works/pi-ai` 直接映射到 **源码** `./packages/ai/src/index.ts`，而不是 `dist`。这样开发时改一个包，另一个包立刻看到类型变化，不用先 build。这是 monorepo 的标准做法，Maven 里没有等价物（Maven 必须 install 到本地仓库）。
- 注意 `paths` 和 `exports` 会**打架**：`paths` 是开发期视角（可以看到源码全部），`exports` 是发布后视角（只能看到入口）。所以本地能 import 通、发布后用户报错，是 JS monorepo 的经典坑。

### 1.5 实操

1. 用 `node -e` 或直接 `cat` 把 10 个包的 `dependencies` 全部列出来，**手画依赖图**，验证主线 `telemetry ← ai ← agent ← coding-agent` 是严格单向的。
2. 找出 `agent` 包里哪些文件**没有**被 `index.ts` 导出 —— 那些就是内部实现。
3. 回答：为什么 `session-backends/sqlite-node` 要单独成包，而不是放进 `agent` 的一个子目录？（提示：看它的 `dependencies` 里有没有原生模块）

**验收标准**
- 能说出「一个包对外暴露什么」需要同时看哪三个地方（`exports` / `index.ts` / `paths`）
- 能解释 `import type` 和 `import` 在依赖关系上的区别
- 能指出 Pi 里至少两处「按运行环境切入口」的设计

---

## A2 — 类型即接口（3–4 天）

Java 用 class 和 interface 表达抽象，TS 里 **class 是少数派**。先看数据（`src` 目录内 `export` 计数）：

| 包 | class | interface | type |
|---|---|---|---|
| ai | 6 | 112 | 82 |
| agent | 34 | 127 | 109 |
| coding-agent | 75 | 318 | 155 |
| telemetry | 1 | 12 | 23 |
| tui | 28 | 64 | 21 |

`ai` 包 **6 个 class 对 112 个 interface** —— 一个两万三千行的包几乎没有类。这不是风格问题，是范式差异：**抽象用类型表达，实现用函数和对象字面量提供。**

### 2.1 结构类型：契约不需要声明

```ts
interface Logger { log(msg: string): void }
const myLogger = { log: (m: string) => console.log(m) };  // 直接就是 Logger，不用 implements
```

后果：
- 第三方对象、字面量、甚至函数返回值都能满足你的接口 —— **接口和实现可以零耦合**。
- 反过来，"两个不相关的东西碰巧形状一样"也会被当成兼容。Pi 里用**判别字段**（`type: "xxx"`）来避免这个问题。

### 2.2 判别联合：TS 的主力多态手段

```ts
type SpanStatus = { status: "ok" } | { status: "error"; error?: { name: string; message: string } };
```

（真实代码，[packages/telemetry/src/index.ts:12](../../packages/telemetry/src/index.ts#L12)）

这等价于 Java 21 的 `sealed interface` + `record` + `switch` 模式匹配，但在 TS 里**用得极其频繁**，是表达"一个东西有 N 种形态"的默认手段。配 `switch (x.type)` 编译器会做**穷尽性检查**（漏一个分支就报错）。

**读 Pi 源码时，看到 `switch (event.type)` 就是在读一个状态机 / 协议定义**，这是全项目最高频的结构。

### 2.3 函数类型就是接口

Pi 里最漂亮的一处设计，`agent` 和 `ai` 两个包之间的全部接缝只有一个类型（[packages/agent/src/types.ts:28](../../packages/agent/src/types.ts#L28)）：

```ts
export type StreamFn = (model, context, options?) =>
    AssistantMessageEventStream | Promise<AssistantMessageEventStream>;
```

`agent` 包从不构造 HTTP 客户端，也不 import 任何 provider。它只要求「给我一个能把 context 变成事件流的函数」。

Java 里你会定义 `interface StreamService { Flux<Event> stream(...) }` 加一个实现类加一处 `@Autowired`。TS 里一个 `type` 就完事了 —— **单方法接口直接退化为函数类型**。这是 TS 架构里最重要的简化，见到就要认出来。

### 2.4 泛型：先读懂，别急着写

Pi 用了条件类型、映射类型、字面量类型运算，能做到 `getBuiltinModel("anthropic", "claude-opus-4-5")` 精确推导出 `Model<"anthropic-messages">`。这类"类型级编程"在 Java 里没有对应物（Java 泛型远弱）。

**这个阶段的要求只有：看到复杂泛型不慌，知道它在做类型推导，能用 IDE 悬停看出最终类型。** 会写是 A6 之后的事。

### 2.5 类型不存在于运行时 → 必须运行时校验

因为类型编译后就没了，**任何来自外部的数据（HTTP 响应、配置文件、LLM 返回的工具参数）都不受类型系统保护**。Pi 用 `typebox`（见 `agent` 的依赖）在运行时校验 —— 这就是 Java 里 `@Valid` + Jackson 反序列化那一层，只是必须显式写。

**这是 Java 工程师最容易踩的坑**：以为标了类型就安全了。没有。

### 2.6 实操

精读两个文件，逐行能解释：

1. [packages/ai/src/types.ts](../../packages/ai/src/types.ts)（830 行，**纯类型，零逻辑**）—— 重点 `Message`、`Context`、`AssistantMessageEvent`、`StreamFunction`。这一个文件覆盖 80% 你会遇到的类型写法。
2. [packages/telemetry/src/index.ts](../../packages/telemetry/src/index.ts)（357 行）—— 一个完整的、零依赖的端口定义长什么样。

**验收标准**
- 能画出 `AssistantMessageEvent` 判别联合的全部分支，并说出每个分支什么时候产生
- 能说明「为什么 `ai` 包只有 6 个 class」，并举出它在哪些场景仍然用了 class
- 能解释在什么情况下必须写运行时校验，Pi 用什么做

---

## A3 — 组装与依赖注入（2–3 天）

没有 Spring 容器，依赖怎么给？TS 里只有三种形态，Pi 三种都用了。

### 3.1 三种 DI 形态

| 形态 | 长什么样 | Spring 对应 | 用在哪 |
|---|---|---|---|
| **参数注入** | `function run(deps: {streamFn, tools, telemetry}) {...}` | 构造器注入 | 最主流，Pi 的核心循环就是这么拿依赖的 |
| **工厂 + 闭包** | `function createX(dep) { return { method() { /* 用 dep */ } } }` | `@Bean` 方法 | 需要私有状态时，闭包变量 = private 字段 |
| **对象字面量实现接口** | `const noopTelemetry: TelemetryContext = { startSpan: ... }` | 一个 `@Component` | 无状态的策略实现，见 `telemetry/src/noop.ts` |

**关键认知**：因为没有容器，**依赖关系全部写在函数签名里**。这意味着读一个函数的签名就读到了它的全部依赖 —— 比 Java 到处翻 `@Autowired` 其实更清晰，代价是要一路手动往下传（俗称 prop drilling）。

### 3.2 class 什么时候还用

不是不能用 class，是**只在有生命周期或可变状态时才用**。规律：

- 纯策略、纯转换 → 函数
- 有内部可变状态 + 多个方法共享 → class（`agent` 34 个、`coding-agent` 75 个 class，基本都是这类）
- 只有一个方法的接口 → 直接用函数类型（见 A2.3）

对照你的习惯：Spring 里你会给每个 Service 建一个类，TS 里那个类通常应该是**一个导出的函数**。

### 3.3 注册表（Registry）代替 ApplicationContext

Pi 的 `ai` 包核心结构：

- `src/api/*.ts` —— ~10 种线上协议（wire format），每种一个模块
- `src/providers/*.ts` —— 40+ 个 provider，每个只有 15–60 行，因为大多**共用同一个 api**
- `src/models.ts` —— 一个注册表，按 `model.api` 字段分发

Spring 类比：api 是接口，provider 是配置好的 Bean 定义，`models.ts` 是 ApplicationContext。

**但实现上它只是一个模块级的 Map**（回想 A1.1：模块天然单例）。这是「不用框架实现 IoC」的标准答案，也是你要重点学的模式。

### 3.4 端口-适配器（六边形架构）在 TS 里的样子

`telemetry` 包是教科书案例：
- 定义纯接口，**零依赖，零实现**
- `noop.ts` 提供空实现作为默认值
- 真正的后端（OTLP 之类）由使用方注入

同理 `session-backends/sqlite-node` 单独成包，是为了**让核心包不依赖原生 SQLite** —— 依赖倒置的物理体现。

Java 里你会用 `xxx-api` / `xxx-impl` 两个 Maven 模块做同样的事。TS 里做法一致，只是边界靠 `exports` 而不是模块系统强制。

### 3.5 实操

任选 Pi 的一条链路（推荐从 `coding-agent` 启动到 `agent-loop` 拿到 `StreamFn`），把**依赖是怎么一层层传进去的**画成一张图。注意标出：哪一层做了"装配"（相当于 `@Configuration`），哪一层只是透传。

**验收标准**
- 能指出 Pi 里的"装配点"在哪个文件（相当于 Spring 的配置类）
- 能说出为什么这个项目不需要 DI 框架，以及代价是什么
- 能判断一段新代码该写成函数还是 class

---

## A4 — 异步即架构（2–3 天）

在 Java 里异步是可选的（大部分业务代码同步写就行）。在 Node 里**异步是架构本身** —— 所有 I/O 都是异步的，没有同步版本可选。

### 4.1 单线程事件循环

- 一个线程，一个事件队列。`await` **不阻塞线程**，它挂起当前函数、把控制权还给事件循环。
- 好消息：没有数据竞争，不需要锁。
- 坏消息：**任何 `await` 之后，你之前读到的状态都可能已经被改了**。检查-然后-使用的竞态在 Node 里照样存在，只是粒度是 `await` 而不是指令。
- CPU 密集任务会**卡死整个进程**（没有别的线程接管）。这解释了为什么 Pi 的 TUI 要做差分渲染。

### 4.2 四层异步原语

| 原语 | Java 对应 | 用途 |
|---|---|---|
| `Promise` | `CompletableFuture` | 单个未来值 |
| `async` / `await` | 无（Java 21 虚拟线程最接近） | 把回调写成顺序代码 |
| `AsyncIterable` + `for await` | `Flux` / `Publisher` | **流式** —— Pi 传 LLM 事件流就靠它 |
| `AsyncGenerator`（`async function*`） | 无 | 用顺序代码**生产**一个流 |

没有 Reactor / RxJava 那套操作符，也**没有背压框架** —— 需要限流、合并、缓冲，全部手写。这是 TS 生态的现实：原语简单，组合靠自己。

### 4.3 取消：唯一必须理解的横切关注点

`AbortSignal` / `AbortController` ≈ 协作式的 `Thread.interrupt()`，但**必须显式沿调用链传递**。Pi 的 `src` 目录里有 74 个文件出现 `AbortSignal`。

**为什么这是架构问题**：它污染了几乎所有函数签名。你在 Java 里靠 `ThreadLocal` 或框架隐式传递的上下文（事务、trace、超时），在 TS 里**要么显式传参，要么用 `AsyncLocalStorage`**。Pi 选了显式传参。读源码时看到一堆函数都带 `signal?: AbortSignal`，就是这个原因。

### 4.4 错误处理

- 没有 checked exception，**没有任何编译期强制**。函数会抛什么，只能读文档或读实现。
- 因此库代码常用两种风格：直接 `throw`，或返回 `{ ok: true, value } | { ok: false, error }` 判别联合（回到 A2.2）。
- `try/finally` + `AbortSignal` 是 Pi 里资源清理的主要手段（没有 try-with-resources）。

### 4.5 实操

逐行精读 [packages/ai/src/utils/event-stream.ts](../../packages/ai/src/utils/event-stream.ts)（88 行）。重点搞懂 `async *[Symbol.asyncIterator]()` 每一行在干什么 —— 这 88 行是整个 Pi 流式架构的原子。

**验收标准**
- 能解释「`await` 之后状态可能已变」会导致什么样的 bug，并在 Pi 里找出一处防御代码
- 能手写一个 `AsyncGenerator`，把一个事件流转换成另一个（比如过滤掉某类事件）
- 能说出 `AbortSignal` 为什么必须显式传，以及不传会怎样

---

## A5 — 工程治理（1–2 天）

**核心问题：TS 编译器不强制分层，那 Pi 的架构约束靠什么落地？**

答案：靠 `npm run check` 里挂的一串自定义脚本。打开根 [package.json](../../package.json) 看那一行：

```
biome check --write --error-on-warnings .
  && check:pinned-deps        # 依赖必须锁死具体版本，不许 ^ ~
  && check:ts-imports         # 禁止相对导入写 .js 后缀（必须写 .ts）
  && check:shrinkwrap         # 产品包的依赖树必须固定
  && check:install-lock:coding-agent
  && tsgo --noEmit            # 类型检查
  && check:browser-smoke      # 验证浏览器可用的包没引入 Node API
```

每一条都是一个**架构约束的可执行版本**，源码在 [scripts/](../../scripts/)，都是几十行的 Node 脚本，非常好读。

**这是这个阶段最重要的一课**：在 Java 里这些约束由 Maven / ArchUnit / 编译器提供；在 TS 里**你自己写脚本**。所以读一个陌生 TS 项目，`scripts/` 目录和 CI 配置是理解其架构纪律的第一手材料 —— 比 README 可靠得多。

其余工具链对照：

| Pi 用的 | Java 世界 | 说明 |
|---|---|---|
| npm workspaces | Maven 多模块 | |
| `package.json` | `pom.xml` | |
| `package-lock.json` | 锁定的依赖树 | Pi 把它当代码审查对象 |
| Biome（[biome.json](../../biome.json)） | Checkstyle + Spotless | lint + 格式化二合一，规则很少（只关了 4 条） |
| `tsc` / `tsgo` | `javac` | `tsgo` 是原生实现的快速版 |
| Vitest | JUnit | **Pi 的测试量约等于源码量，测试是最完整的规格说明** |
| `tsx` | `mvn exec` | 直接跑 TS 源码，零编译 |
| esbuild | 无对应物 | 打包成单文件 |
| `declaration` + `declarationMap` | `-parameters` + source jar | 让使用方能跳到源码 |

顺便看一眼 [tsconfig.base.json](../../tsconfig.base.json)，几个值得注意的开关：`strict: true`（必须）、`erasableSyntaxOnly: true`（**禁止用 enum / namespace 等有运行时产物的 TS 语法**，这样才能被 Node 原生剥离）、`moduleResolution: Node16`。**`erasableSyntaxOnly` 是个很强的架构决策**，它意味着这个项目里你永远不会见到 TS `enum`。

**验收标准**
- 能说出 Pi 用哪 6 个检查保证架构约束，各自防什么
- 能解释为什么这个项目不用 TS `enum`
- 能在本地跑通 `npm run check` 并读懂任意一个 `scripts/*.mjs`

---

## A6 — 收口验收（1 天）

不看文档，独立完成下面五件事。做不到就回上一阶段。

1. **画出 Pi 的完整分层图**，标出每条依赖边，并说明这条边是通过什么机制约束的。
2. **解释 `agent` 和 `ai` 的接缝**为什么可以窄到一个 `type`，用 Spring 会怎么写，各自代价是什么。
3. **给 `agent` 包加一个新的公开入口**（比如 `./experimental`），说出要改哪几个文件（至少 3 处）。
4. **找出 Pi 里一处你认为设计得不好的地方**，说明理由和替代方案。
5. **写一份 500 字的对照笔记**：如果用 SpringBoot 实现 `packages/ai` 的 provider / api / models 三层，会长什么样，哪些地方会更啰嗦，哪些地方会更安全。

---

## 附录 A：架构级概念对照表

只列架构相关的，语法级的不列。

| Java / Spring | TypeScript / Node | 差异要点 |
|---|---|---|
| Maven 模块 | npm workspace 包 | |
| `pom.xml` `<modules>` | 根 `package.json` `workspaces` | |
| `module-info.java` `exports` | `package.json` 的 `exports` 字段 | **包的可见性边界在这** |
| package + `public`/`private` | 只有"导出/不导出" + 文件夹约定 | TS 没有包私有 |
| Facade 类 / `package-info` | `src/index.ts`（barrel） | 手写的公开 API 清单 |
| interface | `interface` / `type` | **不需要 `implements`**（结构类型） |
| 单方法 interface | 函数类型（`type Fn = (...) => ...`） | 大量简化 |
| `sealed interface` + record + 模式匹配 | 判别联合 + `switch` | TS 里是主力手段，不是特例 |
| `@Autowired` 构造器注入 | 函数参数传依赖 | 依赖写在签名里 |
| `@Bean` 工厂方法 | 工厂函数 + 闭包 | 闭包变量 = private 字段 |
| ApplicationContext | 模块级 Map（注册表） | 模块天然单例 |
| `@Configuration` 配置类 | 一个"装配"函数 / 入口文件 | |
| `xxx-api` / `xxx-impl` 双模块 | `telemetry` 包（纯接口）+ 注入实现 | 做法一致 |
| `Flux` / `Publisher` | `AsyncIterable` | 没有操作符，没有背压框架 |
| `CompletableFuture` | `Promise` | |
| `Thread.interrupt()` | `AbortSignal` | **必须显式传参** |
| `ThreadLocal` | 显式传参（或 `AsyncLocalStorage`） | Pi 选显式 |
| checked exception | 无 | 靠文档或返回判别联合 |
| try-with-resources | `try/finally` | 无语法糖 |
| `@Valid` + Jackson | typebox / zod 手动校验 | **类型运行时不存在，必须补** |
| ArchUnit / 编译器强制分层 | 自己写 `scripts/*.mjs` | **读架构先读 scripts/** |
| Checkstyle + Spotless | Biome | |
| JUnit | Vitest | |
| 反射 / 注解处理器 | 无（类型已擦除干净） | 所以没有注解驱动框架 |

---

## 附录 B：这条路线的必读文件清单

按阶段顺序，全部是 Pi 的真实代码，总计约 1,700 行：

| 阶段 | 文件 | 行数 | 学什么 |
|---|---|---|---|
| A0/A1 | [packages/telemetry/src/index.ts](../../packages/telemetry/src/index.ts) | 357 | 零依赖的纯端口定义 |
| A1 | [packages/agent/package.json](../../packages/agent/package.json) | — | `exports` 多入口 |
| A1 | [tsconfig.json](../../tsconfig.json) | — | paths 映射到源码 |
| A2 | [packages/ai/src/types.ts](../../packages/ai/src/types.ts) | 830 | 判别联合、泛型、领域建模 |
| A2/A3 | [packages/agent/src/types.ts](../../packages/agent/src/types.ts) | 443 | `StreamFn` 接缝 |
| A3 | `packages/ai/src/models.ts` + `src/providers/*` | — | 注册表模式 |
| A4 | [packages/ai/src/utils/event-stream.ts](../../packages/ai/src/utils/event-stream.ts) | 88 | 异步流原语 |
| A5 | [scripts/check-ts-relative-imports.mjs](../../scripts/check-ts-relative-imports.mjs) 等 | — | 架构约束的可执行版本 |

---

## 需要你确认的三件事

1. **节奏**：12–17 天（每天 2–3 小时）合不合适？如果你想压到一周，我会砍掉 A2 的泛型部分和 A5 的一半，但 A1 和 A3 不能砍。
2. **是否要配练习答案**：每个阶段的"实操"我可以再写一份带答案的详解文档（每份 3–5 千字），还是你先自己做、卡住再问？
3. **要不要 Java 对照代码**：比如把 `StreamFn` 那个接缝用 SpringBoot 完整写一遍做对比。很有效，但会多花 30% 时间。
