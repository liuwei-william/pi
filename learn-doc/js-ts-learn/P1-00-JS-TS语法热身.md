# P1-00 · JS/TS 语法热身

> 目标:让你看 Pi 源码时不会因为"这什么语法"而卡住
> 前置:无
> 读完你应该能:看懂任意一段 Pi 代码的**语法**(不要求懂业务)

这一篇不讲设计,只扫语法盲区。**重点是 Java 里没有、或者长得像但行为不同的东西**——这些才是让你读代码卡壳的真凶。已经和 Java 一样的东西(if/for/while/try-catch)我就不浪费你时间了。

---

## 0. 先建立一个总原则:类型只活在编译期

这是 TypeScript 最重要的一件事,理解了它,很多困惑迎刃而解。

```ts
interface Order {
   id: string;
   amount: number;
}

const order: Order = { id: "O1001", amount: 99.5 };
```

编译之后,`interface Order` **完全消失**,浏览器/Node 运行的是:

```js
const order = { id: "O1001", amount: 99.5 };
```

所以:

| 你在 Java 里会做的 | TS 里能不能做 |
|---|---|
| `if (obj instanceof Order)` | ❌ **不能**。`Order` 是 interface,运行时不存在 |
| `Order.class` / 反射 | ❌ 没有这个东西 |
| `@Valid` 自动校验请求体 | ❌ 类型不参与运行时,**必须手写校验**(Pi 用 TypeBox,见 P1-08) |
| `if (obj instanceof Error)` | ✅ **能**。`Error` 是 class,运行时真实存在 |

一句话:**`interface`/`type` 是给编译器看的注释,`class` 才是真东西。**

Java 的泛型擦除你已经熟悉了——TS 是把这个概念推到了极致:不只是泛型参数擦除,整个类型系统都擦除。

> Pi 的 tsconfig 里有一行 `"erasableSyntaxOnly": true`,意思是**只允许写编译后可以直接擦掉的语法**。这就是为什么 Pi 里从来没有 `enum`(见 §9)。

---

## 1. 变量:只用 `let` 和 `const`

```ts
const shopName = "生鲜优选";   // 不可重新赋值,相当于 Java 的 final
let stock = 100;              // 可重新赋值
var oldStyle = 1;             // ❌ 远古语法,永远不要用
```

**注意 `const` 只锁住"绑定",不锁内容**——和 Java 的 `final` 完全一样:

```ts
const cart = { items: [] };
cart.items.push("苹果");   // ✅ 合法!改的是内容
cart = { items: [] };      // ❌ 报错,改的是绑定
```

Pi 里几乎全是 `const`,Biome 规则 `useConst: "error"` 强制了这一点——能用 `const` 就不许用 `let`。

---

## 2. ⚠️ number 只有一种,而且是 double

**这是 Java 程序员在电商场景最容易踩的坑,没有之一。**

JS 里**没有** `int`/`long`/`float`/`double`/`BigDecimal`,只有一个 `number`,它是 IEEE 754 双精度浮点。

```ts
console.log(0.1 + 0.2);           // 0.30000000000000004  ← 不是 0.3!
console.log(0.1 + 0.2 === 0.3);   // false
```

对应到你的电商业务:

```ts
// ❌ 灾难写法:用 number 存金额
console.log(8.7 * 3);       // 26.099999999999998   应该是 26.1
console.log(16.08 * 5);     // 80.39999999999999    应该是 80.4
console.log(35.41 * 3);     // 106.22999999999999   应该是 106.23
console.log(0.07 * 3);      // 0.21000000000000002  应该是 0.21
```

**注意这个坑的阴险之处:不是每次都出错。** `19.99 * 3` 恰好等于 `59.97`,一点问题没有。所以你测了几个用例都对,上线之后某个特定金额就炸了——**对账差几分钱,查一整天。**

四舍五入也一样不可靠:

```ts
console.log(1.005 * 100);          // 100.49999999999999 → 想四舍五入到 1.01 会变成 1.00
console.log((1.1 + 2.2).toFixed(2)); // "3.30" 看着对,但 1.1+2.2 实际是 3.3000000000000003
```

**正确做法和 Java 一样:金额用最小单位(分)存整数。**

```ts
// ✅ 用「分」存,全程整数运算
const priceInCents = 1999;   // 19.99 元
const qty = 3;
const totalCents = priceInCents * qty;   // 5997,精确

// 只在展示时转成元
function formatYuan(cents: number): string {
   return (cents / 100).toFixed(2);   // "59.97"
}
```

**安全整数范围**:`number` 能精确表示的整数上限是 2^53-1 = `9007199254740991`(`Number.MAX_SAFE_INTEGER`)。

```ts
console.log(Number.MAX_SAFE_INTEGER);      // 9007199254740991
console.log(9007199254740993);             // 9007199254740992  ← 精度丢了!
```

Java 的 `long` 是 2^63,雪花算法生成的订单 ID 经常超过 2^53。**如果你的订单 ID 是 Java 后端的 long,传到 JS 会悄悄丢精度**——这是前后端联调的经典事故。解决办法:**ID 一律用 string 传输**。

```ts
// ❌ 后端返回 { "orderId": 1234567890123456789 }
// ✅ 后端返回 { "orderId": "1234567890123456789" }
interface Order {
   orderId: string;    // ← 用 string,不是 number
   amountCents: number;
}
```

需要大整数运算时用 `bigint`(字面量加 `n` 后缀),但它不能和 `number` 混算:

```ts
const big = 9007199254740993n;   // bigint
console.log(big + 1n);           // 9007199254740994n  精确
console.log(big + 1);            // ❌ TypeError: 不能混合 BigInt 和 Number
```

---

## 3. 两个"空":`null` 和 `undefined`

Java 只有一个 `null`,JS 有两个,这是初学者最迷惑的地方之一。

```ts
let a;                    // undefined —— 声明了但没赋值
const obj = { x: 1 };
console.log(obj.y);       // undefined —— 属性不存在
function f() {}
console.log(f());         // undefined —— 函数没 return

const b = null;           // null —— 我**明确**表示"这里是空的"
```

记忆口诀:
- **`undefined` = 系统给的空**(忘了赋值 / 属性不存在 / 没返回值)
- **`null` = 你主动给的空**(明确表示"查无此人")

实际约定(Pi 也遵守这个):

```ts
interface User {
   id: string;
   nickname?: string;        // 可选字段 → 不存在时是 undefined
   deletedAt: Date | null;   // 必有字段,但值可以是 null(表示未删除)
}
```

`?` 的意思是"这个 key 可能压根不存在",`| null` 的意思是"key 一定在,但值可能是 null"。

**判空的正确姿势**:

```ts
if (value == null) { }    // ← 唯一推荐使用 == 的场景!同时覆盖 null 和 undefined
if (value === null) { }   // 只判 null
if (value === undefined) { }  // 只判 undefined
```

---

## 4. `===` 和 `==`:永远用 `===`

`==` 会做隐式类型转换,规则诡异:

```ts
console.log("1" == 1);      // true   ← 字符串被转成了数字
console.log(0 == false);    // true
console.log("" == false);   // true
console.log(null == undefined);  // true

console.log("1" === 1);     // false  ← 严格比较,类型不同直接 false
```

**规则:永远用 `===` 和 `!==`,唯一例外是上面说的 `== null`。**

**对象比较是引用比较**,和 Java 一样:

```ts
console.log({a:1} === {a:1});   // false,两个不同对象
console.log([1,2] === [1,2]);   // false
```

JS **没有** `equals()` / `hashCode()` 这套约定。要比较内容得自己写,或者用 `JSON.stringify` 糊一下(不严谨,key 顺序敏感)。

---

## 5. 真值与假值(truthy / falsy)

`if` 里可以放任何值,不只是 boolean。**这 6 个是假值,其余全是真值**:

```
false    0    ""(空字符串)    null    undefined    NaN
```

```ts
if ("") console.log("不会执行");
if (0) console.log("不会执行");
if ([]) console.log("会执行!");     // ← 空数组是真值,和 Java 直觉相反
if ({}) console.log("会执行!");     // ← 空对象也是真值
```

**电商场景的经典 bug**:

```ts
// ❌ 库存为 0 时,这个判断会误判成"没传库存"
function updateStock(stock?: number) {
   if (!stock) {
      throw new Error("库存必填");   // stock = 0 时也会抛!
   }
}

// ✅ 明确判断
function updateStock(stock?: number) {
   if (stock === undefined) {
      throw new Error("库存必填");
   }
}
```

同理,`if (!count)` 在 `count = 0` 时、`if (!name)` 在 `name = ""` 时都会误判。**只要值可能合法地是 0 或空串,就不要用真值判断。**

---

## 6. 字符串:模板字面量

反引号 `` ` `` 包裹,`${}` 插值,支持换行。相当于 Java 15 的文本块 + `String.format` 合体:

```ts
const user = "张三";
const amount = 5997;

// 插值
const msg = `${user} 您好,订单金额 ${(amount / 100).toFixed(2)} 元`;

// 多行(不需要 \n 拼接)
const sql = `
   SELECT id, amount
   FROM orders
   WHERE user_id = ?
`;

// 里面可以放任意表达式
const tip = `您还差 ${Math.max(0, 10000 - amount)} 分免运费`;
```

Pi 里到处都是,比如系统提示词的拼装:

```ts
// packages/agent/src/harness/messages.ts:148
content: [{ type: "text" as const, text: BRANCH_SUMMARY_PREFIX + m.summary + BRANCH_SUMMARY_SUFFIX }]
```

---

## 7. 函数:箭头函数和普通函数

```ts
// 三种写法,前两种在 Pi 里最常见
function calcTotal(price: number, qty: number): number {
   return price * qty;
}

const calcTotal2 = (price: number, qty: number): number => {
   return price * qty;
};

const calcTotal3 = (price: number, qty: number) => price * qty;   // 单表达式省略 return
```

**箭头函数不只是简写,它和 `function` 有个关键区别:`this` 的绑定方式。**

```ts
class OrderService {
   private prefix = "[订单]";

   // ❌ 普通函数:this 取决于「怎么调用」
   logBad() {
      setTimeout(function () {
         console.log(this.prefix);   // undefined! this 不是这个实例
      }, 100);
   }

   // ✅ 箭头函数:this 取决于「在哪定义」,自动捕获外层
   logGood() {
      setTimeout(() => {
         console.log(this.prefix);   // "[订单]" 正确
      }, 100);
   }
}
```

**记住这条就够了:回调统一用箭头函数。** 这也是 Pi 的做法——你在 Pi 里几乎看不到独立的 `function () {}` 当回调。

这也解释了你在 Pi 里会看到的 `.bind(this)`:

```ts
// packages/agent/README.md 的例子
streamFn: models.streamSimple.bind(models)
```

把方法从对象上"摘下来"当函数传时,`this` 会丢,所以要 `bind` 回去。Java 的方法引用 `models::streamSimple` 不用操心这个,JS 必须显式处理。

---

## 8. 解构、展开、简写(读 Pi 代码的必备)

### 8.1 解构 destructuring

从对象/数组里"拆"出值,Pi 里极其高频:

```ts
const order = { id: "O1001", amount: 5997, userId: "U88" };

// 对象解构
const { id, amount } = order;
console.log(id, amount);        // O1001 5997

// 重命名
const { id: orderId } = order;

// 给默认值(仅当值是 undefined 时生效)
const { discount = 0 } = order;   // order 没有 discount → 0

// 数组解构(按位置)
const [first, second] = ["苹果", "香蕉"];

// 函数参数上直接解构 —— Pi 里最常见的用法
function ship({ id, userId }: { id: string; userId: string }) {
   console.log(`发货 ${id} 给 ${userId}`);
}
```

Pi 真实代码,注意参数位置的解构:

```ts
// packages/ai/src/providers/anthropic.ts:22
resolve: async ({ ctx, credential, signal }) => { ... }
```

### 8.2 展开 spread `...`

```ts
// 复制并覆盖字段(相当于 Java 的 builder.toBuilder().amount(x).build())
const order = { id: "O1001", amount: 5997, status: "待支付" };
const paid = { ...order, status: "已支付" };   // 新对象,order 不变

// 合并数组
const a = [1, 2], b = [3, 4];
const merged = [...a, ...b];   // [1,2,3,4]

// 浅拷贝
const copy = { ...order };
```

⚠️ **spread 是浅拷贝**,嵌套对象仍是同一个引用:

```ts
const o1 = { user: { name: "张三" } };
const o2 = { ...o1 };
o2.user.name = "李四";
console.log(o1.user.name);   // "李四" ← o1 也被改了!
```

深拷贝用 `structuredClone(obj)`。Pi 就是这么干的:

```ts
// packages/ai/src/utils/validation.ts:318
const args = structuredClone(toolCall.arguments);
```

Pi 里 spread 的高频用法是"传递并覆盖选项":

```ts
// packages/agent/src/agent-loop.ts:308
const response = await streamFunction(config.model, llmContext, {
   ...config,               // 先摊开所有配置
   apiKey: resolvedApiKey,  // 再覆盖这两个
   signal,
});
```

### 8.3 剩余参数 rest `...`

同样的 `...`,在**接收端**就是收集:

```ts
function sum(...nums: number[]): number {
   return nums.reduce((a, b) => a + b, 0);
}
sum(1, 2, 3);   // 6  —— 相当于 Java 的可变参数 int... nums

// 对象 rest:取出一部分,剩下的打包
const { id, ...rest } = order;   // rest = { amount, status }
```

### 8.4 属性简写

```ts
const id = "O1001";
const amount = 5997;

const order = { id, amount };          // 等价于 { id: id, amount: amount }
```

Pi 里到处都是,比如上面那个 `signal,` 就是简写。

---

## 9. 可选链 `?.` 和空值合并 `??`

这两个语法糖会大量出现在 Pi 代码里,必须熟。

```ts
interface Order {
   user?: { address?: { city?: string } };
}

// ❌ 老写法:层层判空
const city1 = order.user && order.user.address && order.user.address.city;

// ✅ 可选链:任何一环是 null/undefined 就整体返回 undefined
const city2 = order.user?.address?.city;
```

`?.` 还能用在方法调用和数组下标上:

```ts
config.transformContext?.(messages);   // 方法存在才调用
list?.[0];                             // 数组存在才取下标
```

Pi 真实代码,注意这两处:

```ts
// packages/agent/src/agent-loop.ts:167  —— 方法可能不存在
let pendingMessages: AgentMessage[] = (await config.getSteeringMessages?.()) || [];

// packages/agent/src/agent-loop.ts:478  —— signal 可能是 undefined
if (signal?.aborted) {
```

**`??` 空值合并**——只在左边是 `null`/`undefined` 时取右边:

```ts
const stock = input ?? 0;
```

**和 `||` 的关键区别**,这是个高频 bug 源:

```ts
const a = 0 || 100;    // 100  ← 0 是假值,被跳过了!
const b = 0 ?? 100;    // 0    ← 0 不是 null/undefined,保留

const c = "" || "默认";  // "默认"
const d = "" ?? "默认";  // ""
```

**规则:只想处理"没有值"的情况就用 `??`;想处理"所有假值"才用 `||`。** 电商里凡是涉及数量、金额、折扣的默认值,一律用 `??`。

Pi 里两者都在用,是有意区分的:

```ts
// packages/coding-agent/src/core/tools/read.ts:214
const ops = options?.operations ?? defaultReadOperations;   // 用 ?? 因为对象不会是假值

// packages/agent/src/agent-loop.ts:167
(await config.getSteeringMessages?.()) || []                // 用 || 因为 undefined 和空数组都想兜底
```

还有一组赋值简写:

```ts
count ??= 0;      // count 是 null/undefined 时才赋 0
name ||= "匿名";   // name 是假值时才赋
flag &&= false;   // flag 是真值时才赋
```

---

## 10. 对象即 HashMap,数组方法即 Stream

### 10.1 对象就是 Map

JS 的对象天然是字符串键的哈希表:

```ts
const stock: Record<string, number> = {
   "SKU001": 100,
   "SKU002": 0,
};

stock["SKU003"] = 50;              // put
const n = stock["SKU001"];         // get
delete stock["SKU002"];            // remove
"SKU001" in stock;                 // containsKey
Object.keys(stock);                // keySet
Object.values(stock);              // values
Object.entries(stock);             // entrySet → [["SKU001",100], ...]
```

`Record<string, number>` 就是 TS 版的 `Map<String, Integer>`(类型层面)。

**但真正的 `Map` 也有**,而且在需要非字符串键、需要保序、需要频繁增删时更好:

```ts
const cache = new Map<string, Order>();
cache.set("O1001", order);
cache.get("O1001");
cache.has("O1001");
cache.delete("O1001");
cache.size;                        // 注意是属性不是方法

const tags = new Set<string>(["生鲜", "促销"]);
tags.add("包邮");
tags.has("生鲜");
```

**选择原则**:key 固定且已知 → 用对象;key 动态、数量大、需要保序 → 用 `Map`。

### 10.2 数组方法 ≈ Java Stream

```ts
const orders = [
   { id: "O1", amount: 5997, status: "已支付" },
   { id: "O2", amount: 1999, status: "待支付" },
   { id: "O3", amount: 8800, status: "已支付" },
];

// map ≈ .stream().map().toList()
const ids = orders.map(o => o.id);                          // ["O1","O2","O3"]

// filter ≈ .stream().filter().toList()
const paid = orders.filter(o => o.status === "已支付");

// find ≈ .stream().filter().findFirst().orElse(null)
const one = orders.find(o => o.id === "O2");                // 找不到返回 undefined

// some / every ≈ anyMatch / allMatch
const hasBig = orders.some(o => o.amount > 8000);           // true
const allPaid = orders.every(o => o.status === "已支付");    // false

// reduce ≈ .reduce()
const total = orders.reduce((sum, o) => sum + o.amount, 0); // 16796

// flatMap / flat
const nested = [[1,2],[3,4]];
nested.flat();                                              // [1,2,3,4]

// sort ⚠️ 原地排序,会改原数组!
const sorted = [...orders].sort((a, b) => a.amount - b.amount);   // 先复制再排
```

**和 Java Stream 的三个关键区别**:

1. **不需要 `.stream()` 和 `.collect()`**,数组直接就有这些方法
2. **不是惰性的**。`orders.filter(...).map(...)` 会遍历两次,生成两个中间数组。数据量大时要注意(几万条以下无所谓)
3. **`sort` 原地修改原数组**,`reverse` 也是。要保持原数组不变,先 `[...arr]` 复制

Pi 里的真实用法:

```ts
// packages/agent/src/agent-loop.ts:203
const toolCalls = message.content.filter((c) => c.type === "toolCall");

// packages/agent/src/agent-loop.ts:607  —— 工具查找就是线性扫描,没有注册表
currentContext.tools?.find((t) => t.name === toolCall.name)
```

---

## 11. class:像 Java,但有几处不同

```ts
export class OrderService {
   // 字段直接声明,不需要写类型也能推断出来
   private readonly prefix = "[订单]";
   private cache = new Map<string, Order>();
   private repo: OrderRepo;

   constructor(repo: OrderRepo) {
      this.repo = repo;
   }

   async findById(id: string): Promise<Order | undefined> {
      return this.cache.get(id) ?? (await this.repo.load(id));
   }

   // getter,外部访问时不带括号:service.size
   get size(): number {
      return this.cache.size;
   }
}
```

上面这个写法有点啰嗦——`repo` 声明了一遍、构造函数参数写了一遍、赋值又写了一遍。TS 其实提供了「参数属性」简写:

```ts
class OrderService {
   constructor(private repo: OrderRepo) {}   // 一行搞定声明+赋值
}
```

**但 Pi 明令禁止这种写法**,所以你在 Pi 源码里只会看到前面那种啰嗦版。

**为什么 Pi 禁止参数属性**?因为 `constructor(private repo: OrderRepo)` 这种写法**编译后需要生成额外代码**,不满足 `erasableSyntaxOnly`。AGENTS.md 明确写了:

> no parameter properties, `enum`, `namespace`/`module`, `import =`, `export =` ... Use explicit fields with constructor assignments.

**同理,Pi 里没有 `enum`**。替代方案是字面量联合类型(下一篇会详讲):

```ts
// ❌ Java 思维
enum OrderStatus { PENDING, PAID, SHIPPED }

// ✅ TS 惯用法,而且更轻(编译后就是字符串)
type OrderStatus = "pending" | "paid" | "shipped";
```

Pi 里满眼都是这个:

```ts
// packages/ai/src/types.ts:82
export type ThinkingLevel = "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
// packages/ai/src/types.ts:393
export type StopReason = "pending" | "stop" | "length" | "toolUse" | "error" | "aborted" | "deferred";
```

**真正的私有字段**用 `#`(运行时强制,不只是编译期):

```ts
class Wallet {
   #balance = 0;         // 真私有,外部拿不到
   private _log = "";    // 只是编译期私有,运行时能访问
}
```

---

## 12. 几个你一定会遇到的语法糖

### `as const` —— 把值"冻"成字面量类型

```ts
const status1 = "paid";                    // 类型推断为 string
const status2 = "paid" as const;           // 类型推断为 "paid"

const config = { retry: 3 } as const;      // 所有字段变 readonly + 字面量类型
```

用途:让 TS 记住"确切的那个值"而不是放宽成 `string`。Pi 的例子:

```ts
// packages/agent/src/harness/messages.ts:138
const content = typeof m.content === "string" ? [{ type: "text" as const, text: m.content }] : m.content;
```

这里如果不写 `as const`,`type` 会被推断成 `string`,就无法匹配 `TextContent` 那个要求 `type: "text"` 的类型了。

### `satisfies` —— 校验但不放宽类型

```ts
// as:强制断言,会丢失精度,也可能骗过编译器
const a = { type: "text", text: "hi" } as TextContent;

// satisfies:检查它符合 TextContent,但保留字面量类型信息
const b = { type: "text", text: "hi" } satisfies TextContent;
```

一句话:**能用 `satisfies` 就别用 `as`**。`as` 是"相信我",`satisfies` 是"帮我检查"。Pi 里的用法:

```ts
// packages/agent/src/agent-loop.ts:513
const finalized = { toolCall, result, isError } satisfies FinalizedToolCallOutcome;
```

### `!` 非空断言

```ts
const model = models.getModel("anthropic", "claude-sonnet-4-6")!;   // 我保证不是 null
```

等于跟编译器说"闭嘴,我知道有值"。**用错了运行时直接崩**。Pi 允许用(Biome 关掉了 `noNonNullAssertion`),但你自己写业务代码时要慎重。

### `?:` 三元和短路

```ts
const label = amount > 10000 ? "大额" : "普通";
const name = user && user.name;          // user 为假值时返回 user 本身
```

### 可选参数与默认值

```ts
function page(size: number = 20, cursor?: string) { }
//                  ^^^^^^^^^ 默认值      ^ 可选,类型是 string | undefined
```

⚠️ 可选参数必须排在必填参数后面,和 Java 可变参数的位置约束类似。

---

## 13. 错误处理:没有 checked exception

```ts
try {
   await payOrder(orderId);
} catch (error) {          // ⚠️ error 的类型是 unknown,不是 Error!
   if (error instanceof Error) {
      console.log(error.message);
   } else {
      console.log(String(error));
   }
} finally {
   release();
}
```

三个和 Java 的关键差异:

1. **`catch` 参数是 `unknown`**。因为 JS 里 `throw` 可以扔任何东西(字符串、数字、对象),所以必须先收窄。Pi 到处都是这个模式:

```ts
// packages/ai/src/api/lazy.ts:20
errorMessage: error instanceof Error ? error.message : String(error),
```

2. **没有 checked exception**,函数签名不声明会抛什么。所以 Pi 用**文档契约**代替——比如 `StreamFn` 的注释明确写着"must not throw",失败要编码成 error 事件。这个思路你在 P1-02 和 P1-06 会反复看到。

3. **自定义错误要继承 `Error`**:

```ts
class InsufficientStockError extends Error {
   readonly sku: string;
   constructor(sku: string) {
      super(`SKU ${sku} 库存不足`);
      this.name = "InsufficientStockError";
      this.sku = sku;
   }
}
```

---

## 14. 一眼认出 Pi 代码里的常见形状

读到下面这些别慌,都是前面讲过的组合:

```ts
// ① 类型导入(只导入类型,编译后整行消失)
import type { Model, Context } from "./types.ts";

// ② 联合类型 + 字面量
export type ToolName = "read" | "bash" | "edit" | "write" | "grep" | "find" | "ls";

// ③ 可选方法 + 可选调用 + 兜底
let pending = (await config.getSteeringMessages?.()) || [];

// ④ spread 覆盖选项
streamFunction(config.model, llmContext, { ...config, apiKey, signal });

// ⑤ 类型守卫(返回 `x is T`,让编译器收窄类型)
function hasApi<TApi extends Api>(model: Model<Api>, api: TApi): model is Model<TApi> {
   return model.api === api;
}

// ⑥ 索引签名 / 映射
export type ProviderEnv = Record<string, string>;

// ⑦ 交叉类型(& 表示"同时是")
export type ProviderStreamOptions = StreamOptions & Record<string, unknown>;

// ⑧ 这个奇怪的 `string & {}` —— 允许任意字符串但保留自动补全提示
export type Api = KnownApi | (string & {});
```

第 ⑧ 个值得单独说一句。`KnownApi | string` 会被 TS 直接压平成 `string`,自动补全就没了。写成 `string & {}` 可以骗过这个压平机制,既接受任意字符串,又在 IDE 里提示已知值。这是社区惯用技巧,Pi 在 `Api`、`ProviderId`、`ImagesApi` 上都用了。

---

## 15. 自测清单

能答上来就可以进 P1-01 了:

1. `interface Order` 编译后还在吗?`class Order` 呢?
2. 电商订单金额 19.99 元,应该怎么在 JS 里存?为什么?
3. 后端 Java 用 `long` 返回订单 ID,前端 JS 接收会有什么问题?
4. `null` 和 `undefined` 分别什么时候出现?怎么一次判掉两个?
5. `const stock = 0; const n = stock || 10;` 结果是几?换成 `??` 呢?
6. `if ([])` 会进分支吗?`if ("")` 呢?
7. 为什么回调要用箭头函数而不是 `function`?
8. `{ ...order }` 是深拷贝还是浅拷贝?要深拷贝用什么?
9. `orders.sort(...)` 会改原数组吗?
10. 为什么 Pi 里没有 `enum`?用什么替代?
11. `as` 和 `satisfies` 的区别是什么?该优先用哪个?
12. `catch (error)` 里 `error` 是什么类型?为什么?

---

## 16. 补充材料

不用系统学,当字典查:

- [MDN JavaScript 指南](https://developer.mozilla.org/zh-CN/docs/Web/JavaScript/Guide) —— 语法权威参考
- [TypeScript 手册](https://www.typescriptlang.org/docs/handbook/intro.html) —— 只看 "Everyday Types" 和 "Narrowing" 两章就够
- 最好的教材还是 Pi 自己:遇到不懂的语法,直接问 pi「解释 `packages/ai/src/types.ts:35` 这个 `string & {}` 是什么意思」

---

**下一篇**:[P1-01 · ESM 模块系统](P1-01-ESM模块系统.md) —— 没有 classpath 的世界怎么组织代码
