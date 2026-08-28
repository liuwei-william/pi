# P1-08 · unknown 与 any:类型安全的边界

> 目标:搞清楚"类型系统管到哪、哪里必须手工兜底",这是 TS 项目的架构问题
> 前置:[P1-00](P1-00-JS-TS语法热身.md)、[P1-04](P1-04-可辨识联合.md)、[P1-05](P1-05-泛型.md)
> 读完你应该能:识别一个项目的"类型边界",并在边界上正确设防

---

## 0. 一句话总结

**`unknown` 是安全的 `Object`,`any` 是关掉类型检查的开关。**

回忆 P1-00 §0 的总原则:**类型只活在编译期**。这意味着任何从外部进来的数据——HTTP 响应、JSON 文件、用户输入、大模型返回的工具参数——**类型标注对它们毫无约束力**。

```ts
const order: Order = JSON.parse(body);    // ⚠️ 编译器信了,但 body 可能是任何东西
console.log(order.amountCents.toFixed(2)); // 💥 运行时:Cannot read property 'toFixed' of undefined
```

Java 里 Jackson 反序列化失败会抛异常,`@Valid` 会拦下非法字段。**TS 里什么都不会发生,直到你用到那个字段。**

**这一篇讲的就是:在哪里、用什么方式补上这道防线。**

---

## 1. 三兄弟:`any` / `unknown` / `never`

```ts
let a: any;        // 什么都能装,什么操作都允许 —— 类型检查关闭
let u: unknown;    // 什么都能装,但什么操作都【不】允许 —— 必须先收窄
let n: never;      // 什么都装不了 —— 不可能存在的值
```

对比表:

| | `any` | `unknown` | Java 对应 |
|---|---|---|---|
| 能赋任何值给它 | ✅ | ✅ | `Object` |
| 能把它赋给别的类型 | ✅ 任何 | ❌ 只能给 `any`/`unknown` | — |
| 直接访问属性 | ✅ 不检查 | ❌ 报错 | 需要强转 |
| 直接调用 | ✅ | ❌ | — |
| 安全性 | ❌ 病毒式传播 | ✅ 强制你处理 | — |

看代码就明白了:

```ts
function handleAny(x: any) {
   x.foo.bar.baz();          // ✅ 编译通过,运行时大概率崩
   const n: number = x;      // ✅ 编译通过,x 可能是字符串
}

function handleUnknown(x: unknown) {
   x.foo;                    // ❌ 报错:"x" is of type "unknown"
   const n: number = x;      // ❌ 报错

   // 必须先收窄
   if (typeof x === "object" && x !== null && "foo" in x) {
      x.foo;                 // ✅ 现在可以了
   }
}
```

**`any` 最危险的地方是它会传播**:

```ts
const data: any = JSON.parse(body);
const order = data.order;              // order 也是 any
const amount = order.amountCents;      // amount 也是 any
const total: number = amount * 3;      // ✅ 编译通过!但 amount 可能是 "abc"
processPayment(total);                 // 💥 类型污染一路传到支付
```

**一个 `any` 能污染整条调用链。** 这就是为什么它被称为"类型系统的逃生舱"——用一次,舱门就一直开着。

**规则:能用 `unknown` 就别用 `any`。**

---

## 2. Pi 的实际选择:15 : 1

我数了一下 Pi 的 `ai` + `agent` + `coding-agent` 三个包:

```
: unknown    342 处
: any         22 处
as any        42 处
as unknown    36 处
```

**`unknown` 是 `any` 的 15 倍。**

有意思的是,Pi 的 lint 配置**明确关掉了**禁止 `any` 的规则:

```jsonc
// biome.json
"suspicious": {
   "noExplicitAny": "off",       // ← 允许写 any
}
```

而 AGENTS.md 又写着:

> No `any` unless absolutely necessary.

**这不矛盾,是个成熟的工程判断**:与其用 lint 规则一刀切(然后大家到处写 `// biome-ignore` 绕过),不如允许它存在,靠代码审查和文化来约束。结果就是 15:1 这个比例——**`any` 只出现在真正必要的地方**。

那"真正必要"是哪些地方?看 §5。

---

## 3. 收窄 `unknown` 的手段

拿到 `unknown` 之后,你有几种办法把它变成能用的类型:

### 方式一:逐步收窄(P1-04 §4 的那套)

```ts
function parseOrder(raw: unknown): Order {
   if (typeof raw !== "object" || raw === null) {
      throw new Error("不是对象");
   }
   if (!("id" in raw) || typeof raw.id !== "string") {
      throw new Error("id 必须是字符串");
   }
   if (!("amountCents" in raw) || typeof raw.amountCents !== "number") {
      throw new Error("amountCents 必须是数字");
   }
   return { id: raw.id, amountCents: raw.amountCents };
}
```

**优点**:零依赖,类型推导完美。
**缺点**:字段一多就写到吐,而且和类型定义会脱节(改了 `Order` 不会提醒你改这里)。

### 方式二:类型守卫封装

```ts
function isOrder(raw: unknown): raw is Order {
   return typeof raw === "object" && raw !== null
      && "id" in raw && typeof raw.id === "string"
      && "amountCents" in raw && typeof raw.amountCents === "number";
}

const data: unknown = JSON.parse(body);
if (isOrder(data)) {
   data.amountCents;        // ✅
}
```

⚠️ **类型守卫是"我保证"**——逻辑写错了编译器不会发现(P1-04 §4 提过)。

### 方式三:schema 校验库(推荐,Pi 用的这个)

```ts
import { Type, type Static } from "typebox";
import { Value } from "typebox/value";

const OrderSchema = Type.Object({
   id: Type.String(),
   amountCents: Type.Number({ minimum: 0 }),
   status: Type.Union([Type.Literal("pending"), Type.Literal("paid")]),
});

type Order = Static<typeof OrderSchema>;      // ← 类型从 schema 生成

function parseOrder(raw: unknown): Order {
   if (!Value.Check(OrderSchema, raw)) {
      const errors = [...Value.Errors(OrderSchema, raw)];
      throw new Error(`订单数据非法: ${errors.map(e => `${e.path}: ${e.message}`).join(", ")}`);
   }
   return raw;                                 // ← Value.Check 是类型守卫,这里已经是 Order 了
}
```

**这是最佳方案**,因为:
- **单一真相源**:类型和校验规则是同一份定义,不可能脱节
- 错误信息带路径,方便排查
- schema 可以序列化成 JSON Schema(Pi 就是靠这个把工具参数描述发给大模型的)

**这就是 Java 的 `@Valid` + DTO 在 TS 里的对应物**,只不过 Java 是"class + 注解",TS 是"schema 值 + 从它推导的类型",方向相反。

**TS 生态的三大 schema 库**:
- **TypeBox**(Pi 用的)—— 直接生成标准 JSON Schema,运行时开销小
- **Zod** —— 最流行,API 最友好,但 schema 不是标准 JSON Schema
- **Valibot** —— 体积最小

Pi 选 TypeBox 的原因很明确:**工具参数的 schema 要原样发给大模型**,而模型要的是标准 JSON Schema。用 Zod 还得再转一层。

---

## 4. 核心概念:类型边界在哪

一个 TS 项目可以划成两个区域:

```
┌─────────────── 外部世界(不可信) ────────────────┐
│  HTTP 请求体    数据库行    环境变量    JSON 文件  │
│  用户输入      第三方 SDK    ⭐ 大模型返回的工具参数 │
└───────────────────┬──────────────────────────┘
                    │
            ╔═══════▼════════╗
            ║   类型边界      ║  ← 在这里【一次性】校验
            ║  (校验 + 收窄)  ║     进去之后就可以信任类型
            ╚═══════┬════════╝
                    │
┌───────────────────▼──────────────────────────┐
│           内部世界(类型可信)                   │
│   领域模型、业务逻辑、纯函数                    │
│   这里不需要再判空、再校验                      │
└──────────────────────────────────────────────┘
```

**原则:边界处校验一次,内部完全信任。**

这跟 Java 里"Controller 层用 `@Valid` 校验 DTO,Service 层拿到的就是可信对象"是完全一样的架构思想。区别只是 TS 里边界不会自动出现,**你必须自己划**。

**Pi 的类型边界在哪?**

| 边界 | 位置 | 怎么设防 |
|---|---|---|
| **大模型返回的工具参数** | `ai/src/utils/validation.ts` | TypeBox 校验 + 强制转换 |
| Provider 的 HTTP 响应 | `ai/src/api/*.ts` | 手工解析 + 逐字段判断 |
| 会话文件(JSONL) | `agent/src/harness/session/jsonl/codec.ts` | 结构校验,失败抛 `JsonlDecodeError` |
| 写入会话前的数据 | `agent/src/harness/session/session.ts:42` | `assertJsonSerializable` |
| 设置文件 | `coding-agent/src/core/settings-manager.ts` | schema 校验 |
| 扩展加载 | `coding-agent/src/core/extensions/loader.ts` | 运行时探测 |
| RPC 消息 | `packages/protocol` | CBOR 解码 + schema 校验 |

**注意第一条是最特殊的**——下一节详说。

---

## 5. Pi 实战一:最不可信的输入源是大模型

这是 agent 系统独有的问题:**大模型返回的工具参数是"结构化的猜测"**。

模型看到你的 JSON Schema,**尽力**生成匹配的 JSON。但它可能:
- 把数字写成字符串(`"limit": "10"`)
- 漏掉必填字段
- 多给字段
- 生成到一半被 `maxTokens` 截断,JSON 都不完整
- 把 `null` 填给可选字段

**所以工具参数必须校验。** 看 `AgentTool` 的定义([packages/agent/src/types.ts:386](../packages/agent/src/types.ts#L386)):

```ts
export interface AgentTool<TParameters extends TSchema = TSchema, TDetails = any> extends Tool<TParameters> {
   label: string;
   /**
    * Optional compatibility shim for raw tool-call arguments before schema validation.
    * Must return an object that matches `TParameters`.
    */
   prepareArguments?: (args: unknown) => Static<TParameters>;
   //                        ^^^^^^^ 进来是 unknown

   execute: (
      toolCallId: string,
      params: Static<TParameters>,     // ← 出去是精确类型
      signal?: AbortSignal,
      onUpdate?: AgentToolUpdateCallback<TDetails>,
   ) => Promise<AgentToolResult<TDetails>>;
}
```

**这个签名把类型边界表达得很清楚**:`prepareArguments` 收 `unknown`,`execute` 收 `Static<TParameters>`。中间那道校验就是边界。

校验实现在 [packages/ai/src/utils/validation.ts:317](../packages/ai/src/utils/validation.ts#L317):

```ts
export function validateToolArguments(tool: Tool, toolCall: ToolCall): any {
   const args = structuredClone(toolCall.arguments);        // ① 深拷贝,不改原始数据
   normalizeOptionalNulls(args, tool.parameters as JsonSchemaObject);   // ② null → undefined
   Value.Convert(tool.parameters, args);                    // ③ 类型强制转换 "10" → 10

   const validator = getValidator(tool.parameters);         // ④ 编译后的校验器(有缓存)
   // ... 非 TypeBox schema 的额外处理

   if (validator.Check(args)) {
      return args;                                          // ⑤ 通过
   }

   const errors = validator.Errors(args)
      .map((error) => `  - ${formatValidationPath(error)}: ${error.message}`)
      .join("\n") || "Unknown validation error";
   throw new Error(...);                                    // ⑥ 失败抛异常,带详细路径
}
```

**注意 ② 和 ③ 这两步"宽容处理"**:

- `normalizeOptionalNulls` —— 有些模型给可选字段填 `null` 而不是省略,这里统一成 `undefined`
- `Value.Convert` —— 字符串 `"10"` 自动转成数字 `10`

**为什么要宽容?** 因为严格拒绝的代价太高:模型会收到错误、重试、再花一次钱。能自动修正的就修正。

**这是 agent 工程特有的权衡**:输入源是概率性的,你得容错。**但容错不等于不校验**——真正不合法的还是要拒绝。

拒绝之后会发生什么?回到 [agent-loop.ts:701](../packages/agent/src/agent-loop.ts#L701) 附近:抛出的错误被捕获,转成 `{ content: [{type:"text", text: 错误信息}], isError: true }` 的工具结果,**喂回给模型**。模型看到错误信息,下一轮自己改正。

**这是个漂亮的闭环**:校验失败不是崩溃,是给模型的反馈。

---

## 6. Pi 实战二:`catch (error)` 一定是 `unknown`

```ts
try {
   await payOrder(id);
} catch (error) {          // ← 类型是 unknown,不是 Error
   error.message;          // ❌ 报错
}
```

**为什么?** 因为 JS 里 `throw` 可以扔任何东西:

```ts
throw "字符串";
throw 42;
throw { code: 500 };
throw null;
```

所以 TS 只能给 `unknown`。标准处理方式:

```ts
catch (error) {
   const msg = error instanceof Error ? error.message : String(error);
}
```

Pi 里这个模式出现了几十次,比如 [packages/ai/src/api/lazy.ts:20](../packages/ai/src/api/lazy.ts#L20):

```ts
errorMessage: error instanceof Error ? error.message : String(error),
```

**建议封装成工具函数**,你自己的项目里会用无数次:

```ts
export function errorMessage(e: unknown): string {
   if (e instanceof Error) return e.message;
   if (typeof e === "string") return e;
   try { return JSON.stringify(e); } catch { return String(e); }
}
```

⚠️ **老代码可能有 `useUnknownInCatchVariables: false`**,那时候 `catch` 参数是 `any`。Pi 用 `strict: true`,所以是 `unknown`。**遇到 `catch (e: any)` 的代码要警惕。**

---

## 7. Pi 实战三:运行时守卫 `assertJsonSerializable`

这个例子展示了"类型管不到的地方要手工兜底"的极致。

**背景**:会话数据要写进 JSONL 文件,重启后读回来重建状态。如果写进去的东西**不能被 JSON 正确往返**,恢复时就会数据损坏。

哪些东西不能?

```ts
const bad1 = { a: 1 }; bad1.self = bad1;          // 循环引用 → JSON.stringify 抛异常
const bad2 = { n: NaN };                          // NaN → 序列化成 null,读回来变了
const bad3 = { d: new Date() };                   // Date → 变字符串,读回来不是 Date
const bad4 = { get x() { return 1; } };           // getter → 值被固化,语义丢失
const bad5 = [1, , 3];                            // 稀疏数组 → 空洞变 null
const bad6 = new Map([["a", 1]]);                 // Map → 序列化成 {}
```

**类型系统完全管不了这些**——`{ d: new Date() }` 在类型上完全合法。

所以 Pi 写了个运行时守卫([packages/agent/src/harness/session/session.ts:42](../packages/agent/src/harness/session/session.ts#L42)):

```ts
export function assertJsonSerializable(value: unknown): void {
   const active = new WeakSet<object>();                     // ① 检测循环引用
   const stack: JsonValidationFrame[] = [{ value }];         // ② 显式栈,不用递归

   while (stack.length > 0) {
      const frame = stack.pop()!;
      if ("exit" in frame) { active.delete(frame.exit); continue; }

      const candidate = frame.value;
      if (candidate === null || typeof candidate === "string" || typeof candidate === "boolean") continue;

      if (typeof candidate === "number") {
         if (!Number.isFinite(candidate)) invalidPayload("contains a non-finite number");   // ③ NaN/Infinity
         continue;
      }
      if (typeof candidate !== "object") invalidPayload(`contains ${typeof candidate}`);
      if (active.has(candidate)) invalidPayload("contains a cycle");                        // ④ 循环
      active.add(candidate);
      stack.push({ exit: candidate });

      if (Array.isArray(candidate)) {
         if (Object.getPrototypeOf(candidate) !== Array.prototype) {
            invalidPayload("contains a non-standard array");                                 // ⑤ 原型检查
         }
         // ... 还检查了 symbol 属性和稀疏数组
      }
      // ...
   }
}
```

**四个值得学的设计:**

- **① `WeakSet` 检测循环**——进入对象时加入,离开时删除。`WeakSet` 不阻止垃圾回收
- **② 显式栈代替递归**——深层嵌套的数据不会爆栈。`{ exit: obj }` 是"离开标记",模拟递归的返回时机
- **③ `Number.isFinite`**——`NaN` 和 `Infinity` 在 JSON 里都变 `null`,是静默的数据损坏
- **⑤ 原型检查**——`Object.getPrototypeOf(x) !== Array.prototype` 能识别出 `class MyArray extends Array` 这种,序列化后会丢失类信息

**参数类型是 `unknown` 而不是 `any`**——这是正确的选择:函数内部必须逐步收窄,不能随便访问属性。

**这个函数体现了核心思想:类型系统保证"形状对",运行时守卫保证"能安全往返"。两者不能互相替代。**

---

## 8. `any` 到底该用在哪

Pi 里那 22 处 `: any` 主要集中在三类场景:

### ① 异构集合的容器类型

```ts
// packages/agent/src/types.ts
tools?: AgentTool<any>[];
```

一个数组里装着参数 schema 完全不同的工具。用 `AgentTool<TSchema>` 也可以,但泛型的协变规则会让某些赋值失败。**这里 `any` 是务实的选择**——反正每个工具执行时会各自校验参数。

### ② 用户自定义的透传数据

```ts
// packages/agent/src/types.ts:386
export interface AgentTool<TParameters extends TSchema = TSchema, TDetails = any> { }

// packages/ai/src/types.ts:437
export interface ToolResultMessage<TDetails = any> { }
```

`TDetails` 是工具附带的自定义数据,框架**完全不解释它**,只负责搬运。默认 `any` 是为了让不关心的调用方少写一个泛型参数。

### ③ 校验函数的返回值

```ts
export function validateToolArguments(tool: Tool, toolCall: ToolCall): any {
```

返回 `any` 是因为**具体类型只有调用方知道**(`Static<TParameters>`)。调用方拿到后立刻赋给精确类型的变量,`any` 就在那一行终止了。

**总结判断标准**:

| 场景 | 用什么 |
|---|---|
| 外部输入(JSON、HTTP、模型返回) | `unknown` + schema 校验 |
| `catch` 参数 | `unknown`(强制的) |
| 确实不关心内容,只做搬运 | `any` 可接受,加注释说明 |
| 泛型协变导致编译不过 | `any` 可接受,但先想想能不能改设计 |
| 只是不想写类型 | ❌ 这不是理由 |

**用 `any` 时的纪律:让它的作用范围尽可能小。**

```ts
// ❌ any 一路传播
const data: any = await fetchExternal();
process(data.items.map(x => x.value));

// ✅ any 立刻终止
const raw: unknown = await fetchExternal();
const data: ExternalData = parseExternalData(raw);   // 边界在这里
process(data.items.map(x => x.value));
```

---

## 9. 相关的几个类型

### `object` vs `{}` vs `Record<string, unknown>`

```ts
let a: object;                    // 任何非原始值(对象、数组、函数)
let b: {};                        // ⚠️ 除了 null/undefined 的任何值(包括数字!)
let c: Record<string, unknown>;   // 字符串键的对象 —— 通常你要的是这个
```

`{}` 是个陷阱:`const x: {} = 42` 是合法的。**想表达"一个对象"时用 `Record<string, unknown>`。**

### `JsonValue` 递归类型

```ts
// packages/ai/src/types.ts:395
export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };
```

**这是个递归类型定义**——JSON 值要么是原始值,要么是 JSON 值的数组/对象。

**比 `unknown` 精确,比 `any` 安全**。用它表达"这里可以放任意 JSON,但必须是合法 JSON"。Pi 用它标注可持久化的字段:

```ts
data?: JsonValue;
```

**这比 `unknown` 好在哪?** 它在类型层面就排除了 `Date`、`Map`、函数这些不能序列化的东西——正好补上了 §7 那个运行时守卫的一部分职责。

**能在类型层面表达的约束,就不要留到运行时。**

---

## 10. 常见坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| `JSON.parse` 直接标注成领域类型 | 运行时 undefined 报错 | 先 `unknown`,再 schema 校验 |
| 用 `any` 图省事 | 类型污染一路传播 | 用 `unknown` + 收窄 |
| `as` 强转当校验用 | 编译通过,运行时崩 | `as` 不做任何检查,要真校验 |
| `catch (e)` 直接 `e.message` | 编译报错 | `e instanceof Error ? e.message : String(e)` |
| 用 `{}` 表示"对象" | 数字也能赋值进来 | 用 `Record<string, unknown>` |
| 内部函数还在到处判空 | 代码冗余 | 边界校验一次,内部信任 |
| 边界没划清,到处都在校验 | 性能差、逻辑重复 | 明确定义类型边界 |
| 忘了模型返回的参数不可信 | agent 收到脏数据崩溃 | 必须走 schema 校验 |
| 类型合法但不可序列化 | 会话文件损坏 | 运行时守卫 + `JsonValue` 类型 |

**特别强调 `as` 和校验的区别:**

```ts
const order = raw as Order;              // ❌ 零检查,只是让编译器闭嘴
const order = parseOrder(raw);           // ✅ 真的验了
```

`as` 是"相信我",不是"检查一下"。P1-00 §12 讲的 `satisfies` 才是"帮我检查"。

---

## 11. 动手练习

**练习 1(体会污染)**:写一段代码,`const data: any = JSON.parse(...)`,然后一路传下去,看 `any` 怎么一直传播到最后。改成 `unknown` 再来一遍,看编译器在哪一步拦住你。

**练习 2(手工收窄)**:实现 `parseOrder(raw: unknown): Order`,只用 `typeof` / `in` / `Array.isArray`,不用任何库。给非法输入(缺字段、类型错、null、数组、字符串)各测一遍。

**练习 3(schema 校验)**:用 TypeBox 重写练习 2:

```ts
const OrderSchema = Type.Object({
   id: Type.String({ minLength: 1 }),
   amountCents: Type.Integer({ minimum: 0 }),
   status: Type.Union([Type.Literal("pending"), Type.Literal("paid")]),
   tags: Type.Optional(Type.Array(Type.String())),
});
```

对比两种写法的代码量和错误信息质量。然后给 schema 加一个字段,看类型是不是自动跟着变了。

**练习 4(模拟模型输出)**:用练习 3 的 schema,分别校验这几个"模型可能返回的脏数据":

```ts
{ id: "O1", amountCents: "5997", status: "paid" }        // 数字写成字符串
{ id: "O1", amountCents: 5997, status: "paid", tags: null }   // 可选字段给 null
{ id: "O1", amountCents: 5997 }                          // 缺必填
{ id: "O1", amountCents: -1, status: "paid" }            // 违反约束
```

哪些能靠 `Value.Convert` 自动修正?哪些必须拒绝?**这个练习能让你真正理解 Pi 为什么要做那两步"宽容处理"。**

**练习 5(错误工具函数)**:实现 §6 的 `errorMessage(e: unknown): string`,处理 Error、字符串、对象、null、循环引用对象。

**练习 6(运行时守卫)**:实现一个简化版 `assertJsonSerializable`,至少检测:循环引用、`NaN`、`Date`、`Map`。用**显式栈**而不是递归,体会 Pi 为什么那么写。

**练习 7(读 Pi 源码)**:打开 [packages/ai/src/utils/validation.ts](../packages/ai/src/utils/validation.ts):
- `normalizeOptionalNulls` 具体在做什么?为什么需要它?
- `Value.Convert` 会做哪些转换?会不会转过头(比如把 `"abc"` 转成 `NaN`)?
- `getValidator` 为什么要缓存?

**练习 8(读 Pi 源码)**:在 Pi 里搜 `as any`(42 处),挑 5 处看它们为什么必须用:

```bash
grep -rn --include='*.ts' "as any" packages/ai/src packages/agent/src | head -20
```

判断哪些是"确实必要",哪些你觉得可以改进。

---

## 12. 自测清单

1. `any`、`unknown`、`never` 三者的区别?各对应 Java 的什么?
2. 为什么说 `any` 会"传播"?举个例子。
3. `const order: Order = JSON.parse(body)` 有什么问题?Java 里对应的代码有这个问题吗?
4. Pi 里 `unknown` 和 `any` 的比例是多少?为什么 lint 允许 `any` 但规约又说少用?
5. 收窄 `unknown` 的三种方式各有什么优缺点?
6. 什么是"类型边界"?怎么在项目里划?对应 Java 的什么架构实践?
7. Pi 的类型边界有哪些?为什么"大模型返回的工具参数"最特殊?
8. `validateToolArguments` 里为什么要做 `normalizeOptionalNulls` 和 `Value.Convert`?
9. 工具参数校验失败后会发生什么?为什么不是直接崩溃?
10. `catch (error)` 为什么是 `unknown`?标准处理方式是什么?
11. `as Order` 和 `parseOrder(raw)` 有什么本质区别?
12. 哪些数据"类型合法但不能 JSON 往返"?为什么类型系统管不了?
13. `assertJsonSerializable` 为什么用显式栈而不是递归?为什么用 `WeakSet`?
14. `JsonValue` 比 `unknown` 好在哪?
15. `object`、`{}`、`Record<string, unknown>` 该用哪个?

---

## 13. P1 阶段完结

八个要点都过完了。回头看,它们其实指向同一件事——**TS 是一门"编译期很强、运行时什么都没有"的语言**:

| 篇 | 讲的是 | 背后的同一件事 |
|---|---|---|
| P1-01 模块 | 路径即身份 | 没有 classpath,没有反射 |
| P1-02 异步 | 单线程事件循环 | 没有线程,没有锁 |
| P1-03 结构化类型 | 形状匹配 | 没有名义类型,没有 DI 容器 |
| P1-04 可辨识联合 | 数据 + switch | 没有 sealed class,靠 `never` 兜底 |
| P1-05 泛型 | 类型级编程 | 编译期极强,运行时全擦除 |
| P1-06 异步迭代 | 语言内建的流 | 没有响应式框架,没有背压 |
| P1-07 取消 | 显式传 signal | 没有 ThreadLocal,没有强制中断 |
| P1-08 unknown/any | 类型边界 | **类型不参与运行时,边界必须手工设防** |

**最后一篇是前面所有篇的收口**:正因为类型全部擦除,你才必须自己想清楚"哪里是不可信的外部世界,哪里是可信的内部世界"。

**下一步**:进入 [P2 · LLM API 层](00-学习路线图.md#p2--llm-api-层packagesai7-10-天),开始读 `packages/ai`。第一个任务就是逐行啃 [packages/ai/src/types.ts](../packages/ai/src/types.ts)——那 830 行会把这八篇的内容全部用上一遍。

---

**上一篇**:[P1-07 · AbortSignal 与取消](P1-07-取消与AbortSignal.md)
**返回**:[学习路线图](00-学习路线图.md)
