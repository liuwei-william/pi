# P1-01 · ESM 模块系统

> 目标:理解没有 classpath 的世界里,代码怎么组织、怎么被找到
> 前置:[P1-00](P1-00-JS-TS语法热身.md)
> 读完你应该能:看懂 Pi 任意文件顶部的 import 块,并说清楚每个 import 的来源和加载时机

---

## 0. 一句话总结

**Java 里"类的身份"是 `包名.类名`,由 classpath 解析;JS 里"模块的身份"就是文件路径本身。**

这一个差异衍生出后面所有的不同。

---

## 1. 心智模型对照

先把两套体系摆在一起看:

| 概念 | Java | JS / TS (ESM) |
|---|---|---|
| 编译/加载单元 | `.class` 文件 | `.js` / `.ts` **文件** |
| 身份标识 | `com.shop.order.OrderService` | `./core/order/service.ts`(路径) |
| 可见性控制 | `public` / `protected` / 包私有 / `private` | **只有两档:`export` 了就是公开,没 `export` 就是文件私有** |
| 依赖查找 | classpath 扫描 | 相对路径 + `node_modules` 逐级向上查找 |
| 依赖声明 | `pom.xml` `<dependency>` | `package.json` `dependencies` |
| 依赖产物 | `.jar` | `node_modules/<包名>/` 目录 |
| 同名冲突 | 全限定名区分 | 路径天然唯一;导入时可 `as` 重命名 |
| 循环依赖 | 编译通常能过,运行可能 NPE | 编译能过,**运行时可能拿到 undefined** |

**最重要的一条:JS 没有"包级私有"。** 一个文件里的东西,要么 `export`(全世界可见),要么不 `export`(只有本文件可见)。中间没有档位。

这就是为什么 Pi 大量使用 `index.ts` 作为"门面"——它是在**用目录结构 + barrel 文件模拟包可见性**。后面 §6 会详讲。

---

## 2. 从电商例子入手:导出与导入

假设我们在写订单模块。

### 2.1 命名导出(named export)——最常用

```ts
// order/types.ts
export interface Order {
   id: string;
   amountCents: number;
   status: OrderStatus;
}

export type OrderStatus = "pending" | "paid" | "shipped";

export const MAX_ITEMS_PER_ORDER = 100;

export function isPaid(order: Order): boolean {
   return order.status === "paid";
}

// 没有 export 的,外部永远拿不到 —— 这是文件私有
function internalAudit(order: Order) { /* ... */ }
```

导入侧:

```ts
// order/service.ts
import { Order, OrderStatus, isPaid, MAX_ITEMS_PER_ORDER } from "./types.ts";

// 重命名(解决同名冲突,相当于 Java 只能写全限定名的场景)
import { Order as OrderDTO } from "../api/dto.ts";

// 全部塞进一个命名空间对象
import * as OrderTypes from "./types.ts";
OrderTypes.isPaid(order);
```

### 2.2 也可以先声明后导出

```ts
interface Order { /* ... */ }
function isPaid(order: Order): boolean { /* ... */ }

export { Order, isPaid };                    // 集中在文件底部导出
export { isPaid as isOrderPaid };            // 导出时重命名
```

### 2.3 默认导出(default export)——Pi 几乎不用

```ts
// ❌ Pi 源码里基本看不到
export default class OrderService { }
import OrderService from "./service.ts";    // 导入时名字随便起
```

**为什么 Pi 避开它**:默认导出的名字由导入方随便决定,导致同一个东西在不同文件里叫不同名字,搜索和重构都变难。**命名导出强制全项目用同一个名字。**

唯一的例外是**扩展入口**,因为那是加载器约定的协议:

```ts
// packages/coding-agent/examples/extensions/hello.ts
export default function (pi: ExtensionAPI) {
   pi.registerTool(helloTool);
}
```

加载器要"拿到这个文件的那个东西",它不知道你会起什么名字,所以约定用 default。这跟 Spring 的 `@Component` 靠注解让容器识别是同一类问题的不同解法。

---

## 3. ⚠️ `import type` —— 你必须立刻养成的习惯

这是 TS 特有的,也是 Pi 代码里出现频率最高的形式之一。

```ts
import type { Order } from "./types.ts";     // 只导入类型
import { isPaid } from "./types.ts";         // 导入值(函数/常量/class)
```

**区别在编译产物**:

```ts
// 源码
import type { Model, Context } from "./types.ts";
import { EventStream } from "./utils/event-stream.ts";

// 编译后的 JS
import { EventStream } from "./utils/event-stream.js";
// ↑ 那行 import type 整行消失了
```

为什么重要?三个原因:

1. **避免不必要的运行时依赖**。只用到类型却写成普通 import,会让打包器真的去加载那个文件。
2. **打破循环依赖**。类型之间循环引用是完全合法的(类型不存在于运行时),但如果写成普通 import 就会变成真实的运行时循环。
3. **Node 的 strip-only 模式必须靠它**。Node 直接跑 `.ts` 时只是"擦掉类型",它没有类型信息,无法判断 `import { Order }` 里的 `Order` 是类型还是值。写 `import type` 就是明确告诉它"这行可以整个删掉"。

Pi 的规则(AGENTS.md):所有 `packages/*/src` 都在 `erasableSyntaxOnly` 下,所以**只要导入的是 interface / type,就必须写 `import type`**。

Pi 真实代码,注意两种 import 并存:

```ts
// packages/ai/src/api/anthropic-messages.lazy.ts —— 全文只有 4 行
import type { ProviderStreams } from "../types.ts";        // 类型,编译后消失
import { lazyApi } from "./lazy.ts";                       // 值,编译后保留

export const anthropicMessagesApi = (): ProviderStreams => lazyApi(() => import("./anthropic-messages.ts"));
```

还有个混合写法,内联标注:

```ts
import { type Model, createModels } from "./models.ts";    // Model 是类型,createModels 是值
```

Pi 里两种都在用。

---

## 4. 路径:相对路径 vs 裸模块名

```ts
// ① 相对路径 —— 指向你自己项目里的文件
import { Order } from "./types.ts";           // 同目录
import { db } from "../infra/db.ts";          // 上级目录
import { log } from "../../utils/log.ts";     // 上上级

// ② 裸模块名(bare specifier)—— 去 node_modules 找
import { Type } from "typebox";
import { Agent } from "@earendil-works/pi-agent-core";

// ③ Node 内置模块 —— 加 node: 前缀
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
```

**裸模块名的解析规则**(相当于 Java 的 classpath 查找):

从当前文件所在目录开始,逐级向上找 `node_modules/<模块名>/`,直到文件系统根目录。

```
/Users/you/shop/src/order/service.ts  里 import "typebox"
  → 找 /Users/you/shop/src/order/node_modules/typebox   没有
  → 找 /Users/you/shop/src/node_modules/typebox          没有
  → 找 /Users/you/shop/node_modules/typebox              ✅ 找到
```

在 Pi 这样的 **monorepo** 里,`packages/agent/src/xxx.ts` 里写 `import "@earendil-works/pi-ai"`,最终会解析到仓库根的 `node_modules/@earendil-works/pi-ai`,而它其实是一个**符号链接**,指向 `packages/ai/`。这就是 npm workspaces 的核心机制——**本地包之间可以像用外部依赖一样互相 import,但改了立刻生效,不需要发布**。

相当于 Maven 多模块里 `mvn install` 到本地仓库,只不过 npm 用软链接做到了零延迟。

---

## 5. ⚠️ Pi 特有:import 必须写 `.ts` 后缀

```ts
import { Order } from "./types.ts";     // ✅ Pi 的写法
import { Order } from "./types";        // ❌ Pi 里不允许
import { Order } from "./types.js";     // ❌ 也不是 Pi 的写法
```

这一点会让你困惑,因为**网上绝大多数 TS 教程都是不写后缀的**。原因:

- **ESM 规范要求完整路径**(浏览器不会帮你猜后缀),所以标准做法是写 `.js`,哪怕源文件是 `.ts`
- **Pi 选择直接写 `.ts`**,配合 tsconfig 的两个选项:

```jsonc
// tsconfig.base.json
"allowImportingTsExtensions": true,       // 允许 import 里写 .ts
"rewriteRelativeImportExtensions": true,  // 编译时自动把 .ts 改写成 .js
```

好处是**源码可以被 Node 直接执行**(`./pi-test.sh` 就是这么跑的,用 tsx 无需编译),同时编译产物又是合法的 ESM。

项目甚至有个脚本专门检查这条规则:`npm run check:ts-imports` → `scripts/check-ts-relative-imports.mjs`。

**记住:在 Pi 里改代码,相对路径 import 一律写 `.ts`。**

---

## 6. barrel 文件:用 `index.ts` 模拟"包可见性"

前面说 JS 没有包私有。Pi 的解法是:**目录内部随便 import,外部只能通过 `index.ts`**。

电商版示例:

```
order/
├── index.ts          ← 门面,只导出对外 API
├── service.ts
├── repository.ts     ← 内部实现,不希望外部直接用
└── validator.ts      ← 内部实现
```

```ts
// order/index.ts
export { OrderService } from "./service.ts";
export type { Order, OrderStatus } from "./types.ts";
// repository.ts 和 validator.ts 故意不导出 → 对外不可见
```

外部只写 `import { OrderService } from "../order/index.ts"`,团队约定不许直接 import `../order/repository.ts`。

**注意这是纪律,不是强制。** 编译器不会拦你。真正的强制手段是 §7 的 `exports` 字段。

看 Pi 的真实 barrel,[packages/ai/src/index.ts](../packages/ai/src/index.ts):

```ts
export type { Static, TSchema } from "typebox";
export { Type } from "typebox";

// Core only, side-effect free: no generated catalogs, no provider factories,
// no api-registry, no OAuth implementations, no compat. ...
export type { AnthropicEffort, AnthropicOptions, AnthropicThinkingDisplay } from "./api/anthropic-messages.ts";
export * from "./api/lazy.ts";
export * from "./models.ts";
export * from "./types.ts";
export * from "./utils/event-stream.ts";
export { contentText } from "./utils/text.ts";
export { uuidv7 } from "./utils/uuid.ts";
```

三个值得注意的点:

**① `export *` 是"转发全部"**,相当于把那个文件的所有导出原样搬到这里。

**② `export type { X }` 转发的是纯类型**,编译后消失。

**③ 那段注释非常关键**:"Core only, **side-effect free**"。

什么叫副作用?见下一节。

---

## 7. 副作用导入,以及为什么 Pi 要刻意避开它

```ts
import "./providers/images/register-builtins.ts";    // 不取任何东西,只为了"让它运行"
```

这行的作用是执行那个文件的顶层代码——通常是往某个全局注册表里塞东西。看 Pi 的 [packages/ai/src/images.ts](../packages/ai/src/images.ts) 第一行就是这个。

**类比 Spring**:相当于 `@Component` 扫描时把 bean 注册进容器。区别是 Spring 有容器统一管理,而 JS 里这是靠"import 这个文件"这个动作触发的隐式行为。

**为什么 `index.ts` 要 side-effect free**?因为现代打包器有 **tree shaking**(摇树优化):没被用到的导出会被删掉,减小产物体积。但**只要一个模块有副作用,打包器就不敢删它**。

Pi 的取舍是:核心 `index.ts` 保持纯净可摇树,把有副作用的东西(provider 注册、OAuth 实现、生成的模型目录)推到**子路径**里,用的人自己按需导入:

```ts
import { createModels } from "@earendil-works/pi-ai";              // 核心,轻
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";  // 只要这一家
import { builtinModels } from "@earendil-works/pi-ai/providers/all";            // 要全部(重)
```

这些子路径不是随便写的,由 `package.json` 的 `exports` 字段定义:

```jsonc
// packages/ai/package.json
"exports": {
   ".":              { "types": "./dist/index.d.ts",       "import": "./dist/index.js" },
   "./compat":       { "types": "./dist/compat.d.ts",      "import": "./dist/compat.js" },
   "./providers/*":  { "types": "./dist/providers/*.d.ts", "import": "./dist/providers/*.js" },
   "./api/*":        { "types": "./dist/api/*.d.ts",       "import": "./dist/api/*.js" },
   "./oauth":        { "types": "./dist/oauth.d.ts",       "import": "./dist/oauth.js" }
}
```

**`exports` 才是真正的强制封装**:没在这里列出来的路径,外部**根本 import 不到**,哪怕文件真实存在。

```ts
import { x } from "@earendil-works/pi-ai/utils/estimate";   // ❌ 报错:exports 里没这条
```

**这就是 JS 世界最接近 Java 包可见性的东西**——但它只在跨 npm 包时生效,包内部依然是裸奔状态。

---

## 8. 动态 `import()`:运行时才加载

前面的 `import` 都是静态的:必须写在文件顶部,在模块加载时就全部解析完。

**动态 import 是个返回 Promise 的函数**,可以写在任何地方,按需加载:

```ts
const module = await import("./heavy-report-generator.ts");
module.generate();
```

电商场景的典型用途:

```ts
// 导出 Excel 的库有 10MB,只有点了"导出"才加载
async function exportOrders(orders: Order[]) {
   const { writeXlsx } = await import("./xlsx-writer.ts");   // 用到时才加载
   return writeXlsx(orders);
}
```

**Pi 用它做了一件很聪明的事:让 20+ 个 provider 的 SDK 不必在启动时全部加载。**

看 [packages/ai/src/api/anthropic-messages.lazy.ts](../packages/ai/src/api/anthropic-messages.lazy.ts),整个文件 4 行:

```ts
import type { ProviderStreams } from "../types.ts";
import { lazyApi } from "./lazy.ts";

export const anthropicMessagesApi = (): ProviderStreams => lazyApi(() => import("./anthropic-messages.ts"));
```

`anthropic-messages.ts` 是 1370 行,还会拉起 Anthropic 官方 SDK。如果 10 个 API 全静态导入,启动时就要加载全部——但你一次只用一个模型。

`lazyApi` 的实现([api/lazy.ts](../packages/ai/src/api/lazy.ts)):

```ts
export function lazyApi(load: () => Promise<ProviderStreams>, capabilities?: LazyApiCapabilities): ProviderStreams {
   const api: ProviderStreams = {
      stream: (model, context, options) =>
         lazyStream(model, async () => (await load()).stream(model, context, options)),
      streamSimple: (model, context, options) =>
         lazyStream(model, async () => (await load()).streamSimple(model, context, options)),
   };
   return api;
}
```

注释里有一句关键的:

> The module loads on first stream call; **the host's import cache deduplicates loads**.

**ESM 模块是单例的**——同一个路径无论 import 多少次,只会执行一次,结果被缓存。这跟 Spring 默认的单例 bean 是同一个概念,只不过 JS 是语言层面自带的。

这里还藏着一个精妙设计:`lazyStream` 让函数**同步返回一个流对象**,而加载和认证在背后异步进行。这样调用方不用 `await` 就能拿到流,加载失败会变成流里的一个 `error` 事件。这个"永不抛异常"的契约你在 P1-06 会再遇到。

---

## 9. ⚠️ Pi 的硬规则:禁止内联 import

AGENTS.md 写得很明确:

> **No inline imports** (`await import()`, `import("pkg").Type`, dynamic type imports). Top-level imports only.

等一下——上面第 8 节 Pi 自己不是在用 `import()` 吗?

**不矛盾。** 区别在于:

| 写法 | 允许? | 说明 |
|---|---|---|
| 顶部 `import { x } from "y"` | ✅ | 标准做法 |
| `.lazy.ts` 文件里的 `() => import("./impl.ts")` | ✅ | **刻意设计的懒加载边界**,集中在专门的文件里 |
| 业务函数里随手 `const x = await import("./y.ts")` | ❌ | 这就是"内联 import" |
| `import("pkg").SomeType` 当类型用 | ❌ | 应该写顶部 `import type` |

**为什么禁**:内联 import 让依赖关系藏在函数体里,静态分析工具和人都看不出来。Pi 的做法是把懒加载**收敛成一种显式的模式**——所有需要懒加载的都放在 `*.lazy.ts` 里,一眼就知道边界在哪。

这是个很好的工程思路:**不是禁止某个能力,而是限定它只能出现在特定位置。**

---

## 10. 循环依赖:比 Java 更危险

```ts
// order.ts
import { User } from "./user.ts";
export const ORDER_PREFIX = "ORD-";
export interface Order { user: User; }

// user.ts
import { ORDER_PREFIX } from "./order.ts";
export interface User { lastOrderId: string; }
console.log(ORDER_PREFIX);      // ⚠️ 可能是 undefined!
```

Java 里类之间循环引用基本无害(JVM 懒加载 + 链接期解析)。**JS 里循环 import 会导致某个模块拿到"还没初始化完"的值**——不报错,就是 `undefined`,极难排查。

**两条实用规则:**

1. **类型的循环引用完全安全**。用 `import type` 就永远不会有这个问题,因为编译后那行就没了。

```ts
import type { User } from "./user.ts";    // ✅ 循环也无所谓
```

2. **值的循环引用要拆**。常见做法是把共享的东西抽到第三个文件:

```
order.ts ──┐
           ├──→ constants.ts
user.ts  ──┘
```

Pi 的分层设计(`types.ts` 只放类型、`utils/` 只放叶子工具)本质上就是在结构上杜绝循环。

---

## 11. npm workspaces:monorepo 是怎么串起来的

回顾一下你在 P0 看到的结构:

```jsonc
// 仓库根 package.json
{
   "workspaces": [
      "packages/*",
      "packages/session-backends/*",
      "packages/coding-agent/examples/extensions/with-deps",
      ...
   ]
}
```

`npm install` 时会:
1. 把所有 workspace 包的依赖**提升**到根 `node_modules`(去重)
2. 给每个 workspace 包在根 `node_modules` 里建**软链接**

结果就是:

```
node_modules/
├── @earendil-works/
│   ├── pi-ai         → ../../packages/ai          (软链接)
│   └── pi-agent-core → ../../packages/agent       (软链接)
├── typebox/                                        (真实依赖)
└── vitest/
```

所以 `packages/agent` 里写 `import { Model } from "@earendil-works/pi-ai"`,实际读的是 `packages/ai/` 的代码,改完立刻生效。

**但有个陷阱**:软链接指向的是 `packages/ai/`,而它的 `package.json` 里 `exports` 指的是 `./dist/index.js`——**需要先 build**。

Pi 用 vitest 的别名绕开了这个问题,让测试直接读源码:

```ts
// vitest.base.ts
resolve: {
   alias: [
      { find: /^@earendil-works\/pi-ai$/,         replacement: workspaceSourcePaths.aiIndex },
      { find: /^@earendil-works\/pi-agent-core$/, replacement: workspaceSourcePaths.agentIndex },
      { find: /^@earendil-works\/pi-ai\/providers\/(.+)$/, replacement: `${...}/$1.ts` },
   ],
}
```

**这就是为什么你可以改完源码直接跑测试,不用 build。** `./pi-test.sh` 用 tsx 也是同理。

---

## 12. 实战:读懂一个 Pi 文件的 import 块

拿 [packages/ai/src/providers/anthropic.ts](../packages/ai/src/providers/anthropic.ts) 开头逐行拆:

```ts
import { anthropicMessagesApi } from "../api/anthropic-messages.lazy.ts";
import { lazyOAuth } from "../auth/helpers.ts";
import { loadAnthropicOAuth } from "../auth/oauth/load.ts";
import type { ApiKeyAuth } from "../auth/types.ts";
import { ANTHROPIC_API_KEY_ENV, ANTHROPIC_AUTH_TOKEN_ENV, ANTHROPIC_OAUTH_TOKEN_ENV } from "../env-api-keys.ts";
import { createProvider, type Provider } from "../models.ts";
import { ANTHROPIC_MODELS } from "./anthropic.models.ts";
```

| 行 | 类型 | 解读 |
|---|---|---|
| 1 | 值 | 导入的是 `.lazy.ts` → **真正的 SDK 在第一次调用时才加载** |
| 2–3 | 值 | OAuth 相关,也走懒加载(`lazyOAuth`) |
| 4 | **纯类型** | 只用来标注,编译后消失 |
| 5 | 值 | 环境变量名常量。注意它们是常量不是硬编码字符串 |
| 6 | **混合** | `createProvider` 是函数(值),`Provider` 是类型 |
| 7 | 值 | 生成的模型目录 |

七行 import 就能看出这个文件的全部依赖面。**这是静态 import 的价值:依赖关系一目了然**,也是 Pi 禁止内联 import 的原因。

顺便注意:**所有相对路径都带 `.ts` 后缀**,所有跨目录都是相对路径(没有 `@/xxx` 这种路径别名)。Pi 刻意不用路径别名,因为别名需要构建工具配合,而 Pi 要保证源码能被 Node 直接跑。

---

## 13. 常见坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 忘了 `.ts` 后缀 | `npm run check` 报错 | Pi 里相对 import 一律带 `.ts` |
| 该用 `import type` 却用了普通 import | 打包变大 / 出现意外的循环依赖 | 只用作类型标注的,一律 `import type` |
| 循环依赖导致 `undefined` | 运行时某个常量莫名是 undefined | 抽公共文件;类型引用改 `import type` |
| import 了子路径但 `exports` 没配 | `ERR_PACKAGE_PATH_NOT_EXPORTED` | 检查目标包的 `package.json` `exports` |
| 以为 import 会执行多次 | 期望每次 import 都重新初始化 | ESM 模块是单例,只执行一次 |
| 用了 `require` | `require is not defined` | Pi 是纯 ESM(`"type": "module"`),没有 require |
| 在业务函数里 `await import()` | code review 被打回 | 挪到顶部,或建 `*.lazy.ts` |

---

## 14. 动手练习

**练习 1(基础)**:在 `learn-doc/exercises/` 下建一个电商模块,体会封装:

```
exercises/p1-01/
├── order/
│   ├── index.ts        只导出 OrderService 和 Order 类型
│   ├── service.ts
│   ├── repository.ts   不导出
│   └── types.ts
└── main.ts             只 import order/index.ts
```

跑一下:`npx tsx learn-doc/exercises/p1-01/main.ts`

**练习 2(理解 import type)**:故意制造一个循环依赖(`a.ts` 和 `b.ts` 互相 import 一个常量),观察 `undefined`。然后把其中一边改成 `import type`,看问题是否消失。

**练习 3(读 Pi 源码)**:打开 [packages/agent/src/index.ts](../packages/agent/src/index.ts),回答:
- 它导出了哪些**值**?哪些是**纯类型**?
- 它有没有副作用导入?
- 为什么会有一个单独的 `node.ts`(只有 2 行)?这个设计解决什么问题?

**练习 4(验证懒加载)**:在 `packages/ai/src/api/anthropic-messages.ts` 顶部加一行 `console.log("anthropic 模块加载了")`,然后:
- 跑 `./pi-test.sh --list-models`,看它打印了吗?
- 跑 `./pi-test.sh -p "hi"`(用 anthropic 模型),看它打印了吗?

这个实验能让你亲眼看到懒加载生效。**看完记得把 console.log 删掉。**

---

## 15. 自测清单

1. Java 的 `com.shop.OrderService` 对应 JS 里的什么?
2. JS 有几档可见性?怎么模拟"包私有"?
3. `import type` 和 `import` 的编译产物差别是什么?什么时候必须用前者?
4. 为什么 Pi 的相对 import 要写 `.ts` 后缀,而大多数教程不写?
5. `export *` 和 `export type *` 有什么区别?
6. 什么是副作用导入?为什么 `index.ts` 要避免它?
7. `package.json` 的 `exports` 字段起什么作用?它和 `index.ts` 的封装有什么本质区别?
8. 动态 `import()` 返回什么?Pi 用它解决了什么问题?
9. AGENTS.md 禁止"内联 import",但 `.lazy.ts` 里用了 `import()`,矛盾吗?为什么?
10. 循环依赖在 JS 里比 Java 更危险,为什么?两种解法是什么?
11. monorepo 里 `packages/agent` 怎么 import 到 `packages/ai` 的代码?
12. 为什么改完源码不用 build 就能跑测试?

---

**上一篇**:[P1-00 · JS/TS 语法热身](P1-00-JS-TS语法热身.md)
**下一篇**:[P1-02 · async / await / Promise](P1-02-异步与Promise.md) —— 单线程怎么做到高并发
