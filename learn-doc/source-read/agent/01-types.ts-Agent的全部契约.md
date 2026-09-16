# 源码精读 01 · `packages/agent/src/types.ts` —— Agent 的全部契约

> **目标**:读懂 `packages/agent` 的对外契约文件,建立"什么是一个 Agent"的准确认知
> **前置**:[P1-03 结构化类型](../../P1-03-结构化类型.md)、[P1-04 可辨识联合](../../P1-04-可辨识联合.md)、[P1-05 泛型](../../P1-05-泛型.md)
> **读完你应该能**:说清 `StreamFn` 为什么由 agent 定义而不是 pi-ai;指出 `AgentLoopConfig` 的 11 个字段分别插在主循环的哪一步;解释为什么全文 6 处写"绝不许抛"却有 1 处要求"请抛"
> **源码**:[`packages/agent/src/types.ts`](../../../packages/agent/src/types.ts) · 443 行

---

## 0. 定位:443 行,零实现

这个文件**一行实现都没有**,全是 `type` 和 `interface`。

用 Java 打比方:它就是你项目里那个只有接口、没有实现类的 `xxx-api` 模块。`packages/agent` 真正干活的代码在 `agent.ts` 和 `agent-loop.ts`,但**"什么是一个 Agent"这件事,是这个文件定义的**。

> **提前记住一件事**:TS 里所有 `type` 和 `interface` 在编译后会被**完全删掉**,运行时一个字节都不剩。它们只在编译期存在。这和 Java 的 interface(会编译成 `.class`、运行时可反射)完全不同。

---

## 1. 地图:六块东西

| 块 | 行 | 一句话 |
|---|---|---|
| `StreamFn` | 28 | 和 pi-ai 之间唯一的缝 |
| `AgentLoopConfig` | 149 | 主循环的插座板,最大的一块(144 行,占全文近 1/3) |
| `CustomAgentMessages` / `AgentMessage` | 316 / 325 | 让你往消息类型里"加料" |
| `AgentState` / `AgentContext` | 333 / 412 | Agent 的活状态 vs 传给循环的快照 |
| `AgentTool` | 386 | 工具长什么样 |
| `AgentEvent` | 428 | 对外广播的 10 种事件 |

下面**不按行号顺序**讲,按理解顺序讲。

---

## 2. `StreamFn` —— 整个包最重要的一行

```ts
export type StreamFn = (
	model: Model<Api>,
	context: Context,
	options?: SimpleStreamOptions,
) => AssistantMessageEventStream | Promise<AssistantMessageEventStream>;
```

### 2.1 先澄清语法:这里的 `=>` 不是箭头函数

这一整句**没有定义任何函数**,它定义的是「**函数的形状**」。

```ts
// ① 定义一个"形状"(类型别名)—— 没有函数体,永远不会执行
type Foo = (a: number) => string;

// ② 定义一个真的函数 —— 有函数体
const foo = (a: number): string => "hi";
```

`type` 开头的都是①。

Java 里最接近的对应物:

```java
@FunctionalInterface
interface StreamFn {
    AssistantMessageEventStream apply(Model model, Context ctx, Options opts);
}
```

所以这行代码在说:**"我需要一个长这样的函数。谁给我不管。"**

### 2.2 大白话

给我一个模型、一段对话,还给我一个"事件流"。

`packages/agent` 和 `packages/ai` 之间**只通过这一个函数类型连接**。agent 不知道 OpenAI、不知道 Anthropic、不知道 HTTP。它只知道"我手上有个函数,调了会吐事件"。

### 2.3 注释里那段 Contract 才是重点

源码注释翻译:

> - 对于请求/模型/运行时失败,**绝不能抛异常,也不能返回 rejected promise**
> - 必须返回一个 `AssistantMessageEventStream`
> - 失败必须编码进返回的流里:通过协议事件,以及一个 `stopReason` 为 `"error"` 或 `"aborted"`、带 `errorMessage` 的最终消息

**这条规矩很反 Java 直觉。** 在 Spring 里你习惯 `throw new BizException()`,让上层 `@ExceptionHandler` 兜住。这里反过来:**失败不是异常,失败是一个正常的返回值**。

为什么?因为这是**流式**的。假设 LLM 吐到一半网断了——前面已经推给 UI 的那些 token 怎么办?如果这时抛异常,调用方的 `for await` 循环直接炸掉,已经消费的那部分状态就悬空了。

所以设计成:**流正常结束,只是最后那条消息带着 `stopReason: "error"`**。调用方的代码路径**只有一条**,不用写 try/catch。

---

## 3. 【重点】`StreamFn` 到底是谁的?

> 这一节独立成章,因为它是理解整个 monorepo 架构的钥匙。

### 3.1 一个很自然的误解

直觉会觉得:**流式调用模型是 pi-ai 的活,所以 `StreamFn` 应该是 pi-ai 定义的,agent 去 `import` 它。**

**事实正好相反。**

```
packages/ai/ 整个包里搜 "StreamFn" → 出现 0 次
```

pi-ai 根本没有 `StreamFn` 这个东西。它是 `packages/agent` 自己定义的。

### 3.2 为什么?因为接口属于调用方

这个原则你在 Spring 里天天用,只是可能没意识到。想想你写订单服务要发短信:

```java
// 你不会去 import 阿里云 SDK 的接口
// 你会在自己的包里定义:
public interface SmsSender {
    void send(String phone, String content);
}

// 然后让第三方来适配:
public class AliyunSmsSender implements SmsSender { ... }
```

**`SmsSender` 属于 `OrderService`,不属于阿里云。** 因为需求是订单服务提出的。

Martin Fowler 管这个模式叫 **Separated Interface**,更广为人知的名字是**依赖倒置(Dependency Inversion)**。

agent 就是这么干的:"我要跑一个 Agent 循环,循环里得能调模型。模型怎么调我不管,但它必须长成 `StreamFn` 这样。"

### 3.3 证据:依赖方向

```
packages/agent  依赖 → @earendil-works/pi-ai   ✓
packages/ai     依赖 → (没有 agent)             ✗
```

pi-ai 的 `dependencies` 里全是 `openai`、`@anthropic-ai/sdk`、`@google/genai` 这些,**完全不知道 agent 存在**。

而且源码里直接写明了理由 —— [`stream-fn.ts`](../../../packages/agent/src/stream-fn.ts):

> Hosts that provide a default model runtime can install its stream function here
> **without making pi-agent-core depend on a provider catalog or compatibility layer.**
>
> (提供默认模型运行时的宿主可以把它的 stream 函数装在这里,**而不必让 pi-agent-core 依赖 provider 目录或兼容层**。)

### 3.4 agent 确实 import 了,但只 import 名词

看 types.ts 开头:

```ts
import type {
	Api, AssistantMessage, AssistantMessageEvent, AssistantMessageEventStream,
	Context, ImageContent, Message, Model, SimpleStreamOptions,
	TextContent, Tool, ToolResultMessage, Usage,
} from "@earendil-works/pi-ai";
```

这 14 个全是**名词**——数据长什么样。`Model` 是什么、`Context` 是什么、消息有哪些字段。这些**当然要用 pi-ai 的**,不然两边对不上。

但 `StreamFn` 是个**动词**——"该怎么调用"。**动词归调用方定。**

> 记住这个区分:**共享数据结构,但不共享行为契约。**

### 3.5 精髓:没有 `implements`,而且形状根本不完全一样

types.ts 的注释用词很讲究:

> `Models.streamSimple` **satisfies** this shape.

是 **satisfies**(满足),不是 **implements**(实现)。全项目搜不到任何一句 `implements StreamFn`。

**更狠的是,两边签名其实对不上:**

```ts
// agent 定义的(types.ts:28)
(model: Model<Api>, context: Context, options?: SimpleStreamOptions)
  => AssistantMessageEventStream | Promise<AssistantMessageEventStream>

// pi-ai 提供的(ai/src/models.ts:215)
streamSimple(model: Model<Api>, context: Context, options?: ModelsSimpleStreamOptions)
  : AssistantMessageEventStream
```

| | agent 要的 | pi-ai 给的 |
|---|---|---|
| `options` | `SimpleStreamOptions` | `ModelsSimpleStreamOptions`(**超集**) |
| 返回值 | `Stream` 或 `Promise<Stream>` | 只有 `Stream` |

`ModelsSimpleStreamOptions = SimpleStreamOptions & ModelsRequestTransforms`([`ai/src/models.ts:84`](../../../packages/ai/src/models.ts))——多了一组字段。

**如果这是 Java,`implements` 直接编译失败**,方法签名必须一模一样。

但 TS 不问"是不是同一个类型",只问一个问题:**"把它放进这个位置,会出事吗?"**

- **返回值**:pi-ai 只返回 `Stream`,agent 说"`Stream` 或 `Promise<Stream>` 都收" → **给少了反而安全**
- **参数**:agent 只会传 `SimpleStreamOptions`,pi-ai 能接更多 → **接得宽也安全**

不会出事,所以放行。这就是 **structural typing**(结构化类型),详见 [P1-03](../../P1-03-结构化类型.md)。

> 一句话记忆:**Java 问"你是不是我儿子",TS 问"你长得像不像"。**

### 3.6 谁把它们接起来的?第三者

在 [`coding-agent/src/core/sdk.ts:36`](../../../packages/coding-agent/src/core/sdk.ts),就一行:

```ts
import { streamSimple } from "@earendil-works/pi-ai/compat";
import { setDefaultStreamFn } from "@earendil-works/pi-agent-core";

setDefaultStreamFn(streamSimple);
```

和 Spring 的 `@Bean` 干的事一模一样:

| Spring | Pi |
|---|---|
| `OrderService` 声明依赖 `SmsSender` | `agent` 定义 `StreamFn` |
| `AliyunSmsSender` 提供实现 | `pi-ai` 提供 `streamSimple` |
| `@Configuration` 把它们装配起来 | `coding-agent` 调 `setDefaultStreamFn()` |

区别是 Pi 这边**不需要容器、不需要注解、不需要反射**——就是一次普通的函数赋值。装配点看得见,一行代码,可以直接点进去。

实际取用在 [`agent.ts:222`](../../../packages/agent/src/agent.ts):

```ts
this.streamFunction = runtimeOptions.streamFn ?? getDefaultStreamFn();
```

`??` 是空值合并:**显式传入的优先,没传才用全局默认**。

### 3.7 这个设计换来了什么

1. **pi-ai 能独立用** —— 它就是个纯 LLM 客户端,拿去做别的项目也行
2. **agent 好测** —— 测试时塞个假函数,不用起真的网络请求
3. **换实现零成本** —— coding-agent 自己又实现了一个 [`model-runtime.ts:636`](../../../packages/coding-agent/src/core/model-runtime.ts) 的 `streamSimple`,照样能塞进去

这也是为什么说 **`StreamFn` 是这两个包之间唯一的缝**。缝越窄,两边越能各自演化。

> **方法论**:看到一个类型,第一反应应该是"这是谁的?"。判断方法两步:
> 1. `grep` 一下这个名字在哪个包出现
> 2. 看 `package.json` 的依赖方向
>
> 方向永远是从"定义者"指向"被依赖者",反过来就是循环依赖了。

---

## 4. `AgentTool` —— "给 LLM 看的"和"真的要跑的"

```ts
export interface AgentTool<TParameters extends TSchema = TSchema, TDetails = any>
	extends Tool<TParameters> {
	label: string;
	prepareArguments?: (args: unknown) => Static<TParameters>;
	execute: (
		toolCallId: string,
		params: Static<TParameters>,
		signal?: AbortSignal,
		onUpdate?: AgentToolUpdateCallback<TDetails>,
	) => Promise<AgentToolResult<TDetails>>;
	executionMode?: ToolExecutionMode;
}
```

注意 `extends Tool<TParameters>`,`Tool` 来自 pi-ai([`ai/src/types.ts:502`](../../../packages/ai/src/types.ts)):

```ts
export interface Tool<TParameters extends TSchema = TSchema> {
	name: string;
	description: string;
	parameters: TParameters;
	constrainedSampling?: false | ConstrainedSamplingConfig;
}
```

### 4.1 这个继承关系本身就是一课

- **`Tool`(pi-ai)= 给 LLM 看的部分**。名字、描述、参数 schema。这三样会被序列化成 JSON Schema 发给模型。
- **`AgentTool`(agent)= 加上真的能跑的部分**。`execute` 是实现,`label` 是给界面看的名字。

LLM 只需要知道"有个工具叫 `read_file`,要传 `path`",它不需要知道你怎么读的。**这条线划得非常干净。**

### 4.2 一个特别值得注意的不对称

`execute` 的注释(types.ts:394):

> Execute the tool call. **Throw on failure** instead of encoding errors in `content`.

**全文 6 处写着"绝不许抛",只有这一处要求你抛。**

为什么?因为**信任边界在这里**。工具是你(应用开发者)写的代码,agent 框架不信任它——所以框架在 `execute` 外面包了 try/catch,把你的异常转成一条 `isError: true` 的 tool result 喂回给 LLM,让模型自己看着办。

而框架内部的那些 hook,一旦抛了就没人兜了,整个循环会在不该断的地方断掉。

> Java 类比:你的 `@Service` 尽管抛,`@ControllerAdvice` 会兜;但你要是在 `HandlerInterceptor.afterCompletion()` 里抛异常,那就很难看了。

### 4.3 两个泛型参数

```ts
AgentTool<TParameters extends TSchema = TSchema, TDetails = any>
```

- `TParameters` —— 参数的 TypeBox schema。`Static<TParameters>` 把 schema **变成 TS 类型**,所以 `execute` 里的 `params` 是有类型的、能自动补全的
- `TDetails` —— 工具返回的结构化数据类型。给日志和 UI 用,**不发给 LLM**

`= TSchema` 和 `= any` 是**默认值**。Java 泛型没这个,TS 有——不写泛型参数也能用。详见 [P1-05](../../P1-05-泛型.md)。

### 4.4 配套的 `AgentToolResult`(361 行)

```ts
export interface AgentToolResult<T> {
	content: (TextContent | ImageContent)[];   // 给模型看的
	details: T;                                 // 给日志/UI 看的
	usage?: Usage;
	addedToolNames?: string[];                  // 这个结果引入了新工具
	terminate?: boolean;                        // 提示 agent 该停了
}
```

`addedToolNames` 是个很妙的设计:**一个工具的执行结果可以引入新的工具**,从这条消息往后可用。比如"打开了某个项目"之后,项目专属的工具才出现。

`terminate` 的注释强调:**只有这批工具的每一个结果都设了 `true`,才会真的提前终止**。一票否决制。

---

## 5. `AgentLoopConfig` —— 主循环的插座板

149 行到 293 行,**占全文近三分之一**。这是理解 Agent 工程的核心。

它 `extends SimpleStreamOptions`(来自 pi-ai),然后加了 **2 个必填 + 9 个可选**。

### 5.1 必填的两个

| 字段 | 行 | 干什么 |
|---|---|---|
| `model` | 150 | 用哪个模型 |
| `convertToLlm` | 178 | 把 `AgentMessage[]` 转成 LLM 认识的 `Message[]` |

`convertToLlm` 每次调 LLM 前都会跑。为什么需要它?因为你的应用可能往对话里塞了 LLM 不认识的东西——比如一条"文件已保存"的 UI 通知。这个函数负责:能转的转成 user/assistant/toolResult,转不了的**直接过滤掉**。

源码注释里的例子:

```ts
convertToLlm: (messages) => messages.flatMap(m => {
  if (m.role === "custom") {
    return [{ role: "user", content: m.content, timestamp: m.timestamp }];
  }
  if (m.role === "notification") {
    return [];   // UI-only,不给模型看
  }
  return [m];
})
```

`flatMap` 这个用法很妙:返回 `[]` 就是删掉,返回 `[x]` 就是保留,返回 `[a,b]` 就是一变二。Java 8 的 `Stream.flatMap` 一模一样。

### 5.2 可选的九个 —— 按"你能干什么"分三组

#### A 组:改输入(调 LLM 之前动手)

| 字段 | 行 | 干什么 |
|---|---|---|
| `transformContext` | 200 | 在 `convertToLlm` **之前**改整个消息列表 |
| `getApiKey` | 210 | 每次调用前动态取 key |

`transformContext` 的注释直接点名了用途:**"Context window management (pruning old messages)"**——就是上下文压缩。参见 [D11 上下文压缩图](../../diagrams/preview/D11-上下文压缩.png)。

`getApiKey` 存在的理由很实际:GitHub Copilot 的 OAuth token 是短命的,**工具执行阶段可能跑几分钟,跑完 token 就过期了**。所以不能在启动时取一次就完事,得每次现取。

#### B 组:插手工具调用

| 字段 | 行 | 干什么 |
|---|---|---|
| `toolExecution` | 268 | `"sequential"` 还是 `"parallel"`,**默认 parallel** |
| `beforeToolCall` | 277 | 执行前拦截,**可以 block** |
| `afterToolCall` | 292 | 执行后改结果 |

这两个 hook 就是 **Spring AOP 的 `@Before` / `@AfterReturning`**,或者 `HandlerInterceptor` 的 `preHandle` / `postHandle`。

`beforeToolCall` 返回 `{ block: true, reason: "..." }` 就能阻止执行——**权限校验挂这里**。Pi 的"要不要让 AI 执行这条 bash 命令"就是这么实现的。

`afterToolCall` 的注释特别强调合并语义:

> Omitted fields keep the original executed tool result values. **There is no deep merge** for `content`, `details`, or `usage`.

说人话:你给了 `content` 就是**整个数组替换**,不是往里加。

#### C 组:控制循环什么时候停、下一轮怎么跑

| 字段 | 行 | 干什么 |
|---|---|---|
| `shouldStopAfterTurn` | 222 | 返回 true → 这一轮结束后**优雅停止** |
| `prepareNextTurn` | 229 | 换 context / 换模型 / 换 thinking 等级 |
| `getSteeringMessages` | 244 | 干活干到一半**插话** |
| `getFollowUpMessages` | 257 | 本来要停了,**再追加任务** |

后两个的区别很微妙但很重要:

- **steering(方向盘)**:当前这轮的工具调用跑完了,但 agent 还想继续。这时插一条消息进去。注释说得很清楚:*"Tool calls from the current assistant message are not skipped"*——**当前这批工具照跑,不会被打断**。你在终端里 agent 正干活时敲一句话,走的就是这条。
- **follow-up(续杯)**:agent 已经没有工具要调、也没有 steering 消息了,**本来该结束了**。这时如果你返回了消息,它就再来一轮。

`prepareNextTurn` 能返回 `AgentLoopTurnUpdate`(138 行),换掉下一轮的 context、model、thinkingLevel。**上下文压缩之后把新的消息列表塞回去,就是走这里。**

---

## 6. `CustomAgentMessages` —— TS 独有的扩展点,Java 没有

```ts
export interface CustomAgentMessages {
	// Empty by default - apps extend via declaration merging
}

export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages];
```

一个**空的** interface,然后 `AgentMessage` 是「pi-ai 的 `Message`」**或**「`CustomAgentMessages` 里所有值的类型」。

现在它是空的,所以 `AgentMessage` 就等于 `Message`。但你的应用可以这样:

```ts
declare module "@mariozechner/agent" {
  interface CustomAgentMessages {
    artifact: ArtifactMessage;
    notification: NotificationMessage;
  }
}
```

> ⚠️ **照抄会踩坑**:上面这段是**源码注释里的原文**,但里面的包名 `@mariozechner/agent` 是**过时的**。
> Pi 的实际包名是 `@earendil-works/pi-agent-core`(`packages/agent/package.json` 可查)。
> 这是上游从原作者项目改名后遗留的陈旧注释。自己写的时候要用真实包名。

写完这段,**`AgentMessage` 自动变成 `Message | ArtifactMessage | NotificationMessage`**。你没改人家的源码,但你扩展了人家的类型。

这叫 **declaration merging**(声明合并)。**Java 完全没有对应物。** 最接近的思路是 SPI,但 SPI 是运行时找实现,这个是**编译期把类型拼进去**。

`CustomAgentMessages[keyof CustomAgentMessages]` 拆开看:
- `keyof X` = X 的所有 key 组成的联合类型 → `"artifact" | "notification"`
- `X[K]` = 索引访问 → `ArtifactMessage | NotificationMessage`

合起来就是"这个对象所有 value 的类型"。详见 [P1-05](../../P1-05-泛型.md)。

---

## 7. `AgentState` vs `AgentContext` —— 别搞混

### 7.1 `AgentState`(333 行)= Agent 对象**当前的、活的**状态

```ts
systemPrompt: string;
model: Model<any>;
thinkingLevel: ThinkingLevel;
set tools(tools: AgentTool<any>[]);      // 注意是 accessor
get tools(): AgentTool<any>[];
set messages(messages: AgentMessage[]);
get messages(): AgentMessage[];
readonly isStreaming: boolean;
readonly streamingMessage?: AgentMessage;
readonly pendingToolCalls: ReadonlySet<string>;
readonly errorMessage?: string;
```

注释解释了为什么 `tools` 和 `messages` 用 getter/setter 而不是普通字段:

> so implementations can copy assigned arrays before storing them

**这是防御性拷贝。** 你 `agent.state.messages = myArray` 之后,再去改 `myArray`,不会影响 agent 内部。

Java 里你会在 setter 里写 `this.list = new ArrayList<>(list)`,一个道理。区别是 TS 的 `get`/`set` 在**接口层面**就能声明,调用方写起来还是 `x.messages = [...]`,像普通字段一样——**Java 做不到这点,Java 必须写成 `getMessages()` / `setMessages()`**。

`isStreaming` 有个细节:

> This remains true until awaited `agent_end` listeners settle.

**agent 不是发完 `agent_end` 就算空闲了**,得等所有监听器跑完。

### 7.2 `AgentContext`(412 行)= 传给底层循环的**快照**

```ts
systemPrompt: string;
messages: AgentMessage[];
tools?: AgentTool<any>[];
```

注释用词是 "**Context snapshot**"。**State 是活的、会变的;Context 是某一刻拍下来的照片**,交给循环去用。

---

## 8. `AgentEvent` —— 10 个事件,三层生命周期

```ts
export type AgentEvent =
	| { type: "agent_start" }
	| { type: "agent_end"; messages: AgentMessage[] }
	| { type: "turn_start" }
	| { type: "turn_end"; message: AgentMessage; toolResults: ToolResultMessage[] }
	| { type: "message_start"; message: AgentMessage }
	| { type: "message_update"; message: AgentMessage; assistantMessageEvent: AssistantMessageEvent }
	| { type: "message_end"; message: AgentMessage }
	| { type: "tool_execution_start"; toolCallId: string; toolName: string; args: any }
	| { type: "tool_execution_update"; toolCallId: string; toolName: string; args: any; partialResult: any }
	| { type: "tool_execution_end"; toolCallId: string; toolName: string; result: any; isError: boolean };
```

这是**可辨识联合(discriminated union)**,`type` 是判别字段。详见 [P1-04](../../P1-04-可辨识联合.md)。

三层嵌套关系,注释里定义了 turn ——*"a turn is one assistant response + any tool calls/results"*:

```
agent_start
  turn_start                    ← 一个 turn = 一次 assistant 回复 + 它引发的所有工具调用
    message_start               ← assistant 消息开始
    message_update × N          ← 流式,一个 token 一个
    message_end
    tool_execution_start        ← 开始调工具
    tool_execution_update × N   ← 工具自己汇报进度
    tool_execution_end
  turn_end
  turn_start ...                ← 只要还有工具要调,就再来一轮
agent_end
```

Java 类比:Spring 的 `ApplicationEvent` + `@EventListener`。区别是这里用**联合类型**而不是继承树,所以 `switch (event.type)` 时 TS 能帮你检查有没有漏分支(exhaustiveness checking)。

---

## 9. 三条贯穿全文的规矩

### 规矩一:"绝不许抛"是默认,"请抛"是例外

全文 **6 处**写了 `must not throw`:`StreamFn`、`convertToLlm`、`transformContext`、`getApiKey`、`shouldStopAfterTurn`、`getSteeringMessages`/`getFollowUpMessages`。

只有 `AgentTool.execute` **一处**写了 `Throw on failure`。

注释还解释了后果:

> Throwing interrupts the low-level agent loop **without producing a normal event sequence**.

说人话:你抛了,UI 就收不到 `agent_end`,界面会卡在"正在思考"。

**这是在划信任边界**:框架内部的东西必须自己扛住,只有你写的工具允许失败。

### 规矩二:hook 分两类,看返回值就知道

| 返回类型 | 你能干什么 | hook |
|---|---|---|
| `boolean` | 只能**喊停** | `shouldStopAfterTurn` |
| 消息数组 | 能**改数据** | `convertToLlm`、`transformContext`、`getSteeringMessages`、`getFollowUpMessages` |
| 可选的覆盖对象 | 能**改数据,也可以不插手** | `beforeToolCall`、`afterToolCall`、`prepareNextTurn` |

第三类的返回类型都带 `| undefined` —— **返回 undefined 就是"我不插手,按原样来"**。这个约定在三个 hook 里完全一致,读的时候很省力。

### 规矩三:`AbortSignal` 到处传,但框架不强制

`transformContext`、`beforeToolCall`、`afterToolCall`、`AgentTool.execute` 都收 `signal?: AbortSignal`。

注释措辞值得注意:*"The hook **is responsible for honoring it**"*(hook **有责任遵守它**)。

框架不会替你强制中断——JS 是单线程,**没有 `Thread.interrupt()` 这种东西**。取消是**协作式**的:框架给你一个信号,你自己看着办。详见 [P1-07](../../P1-07-取消与AbortSignal.md)。

---

## 10. 建议的阅读顺序

这文件不要从第 1 行往下读,按依赖关系跳着读:

1. **`StreamFn`(28)** —— 5 行,但上面那段 Contract 注释读三遍
2. **`AgentTool`(386)+ `AgentToolResult`(361)** —— 工具是 Agent 的手
3. **`AgentEvent`(428)** —— 先建立"一次运行会发生什么"的时间感
4. **`AgentLoopConfig`(149)** —— 对着上一步的时间线,看每个 hook 插在哪
5. 剩下的 `AgentState` / `AgentContext` / `CustomAgentMessages`,用到再回头查

读完第 4 步,直接去看 [`agent-loop.ts:155`](../../../packages/agent/src/agent-loop.ts) 的 `runLoop`——**那个函数就是把这里每个 hook 按顺序调一遍**。

---

## 附:本文核对过的源码位置

| 内容 | 位置 |
|---|---|
| `StreamFn` | `packages/agent/src/types.ts:28` |
| `AgentLoopConfig` | `packages/agent/src/types.ts:149` |
| `model` / `convertToLlm` | `:150` / `:178` |
| `transformContext` / `getApiKey` | `:200` / `:210` |
| `shouldStopAfterTurn` / `prepareNextTurn` | `:222` / `:229` |
| `getSteeringMessages` / `getFollowUpMessages` | `:244` / `:257` |
| `toolExecution` / `beforeToolCall` / `afterToolCall` | `:268` / `:277` / `:292` |
| `ThinkingLevel` | `:300` |
| `CustomAgentMessages` / `AgentMessage` | `:316` / `:325` |
| `AgentState` | `:333` |
| `AgentToolResult` / `AgentToolUpdateCallback` | `:361` / `:383` |
| `AgentTool` | `:386`,`execute` 的 "Throw on failure" 在 `:394` |
| `AgentContext` / `AgentEvent` | `:412` / `:428` |
| pi-ai 的 `Tool` | `packages/ai/src/types.ts:502` |
| `ModelsSimpleStreamOptions` | `packages/ai/src/models.ts:84` |
| `Models.streamSimple` 签名 | `packages/ai/src/models.ts:215` |
| 装配点 `setDefaultStreamFn(streamSimple)` | `packages/coding-agent/src/core/sdk.ts:36` |
| 取用点 `?? getDefaultStreamFn()` | `packages/agent/src/agent.ts:222` |
| `runLoop` | `packages/agent/src/agent-loop.ts:155` |

**核对方式**:`grep -c "must not throw"` = 6;`AgentEvent` 分支数 = 10;`grep -rn "StreamFn" packages/ai/` = 0 条。
