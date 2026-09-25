# cItem.m_FireworkItem 在插件中能看到什么 —— 含跨架构验证

> 本地 x86-64：Cuberite Jenkins x86_64-linux-gnu Release (master) **#445**，
> commit `ffa3279d66d82b2583363b3a6f2937196f9ca04b`。
> 对照构建：Raspberry Pi **armv6l / ILP32**（`/home/david/cuberite/Cuberite`，本机编译）
> 与官方 **aarch64 / i386** 发布包（`download.cuberite.org`），四者均 not stripped。
> 源码：`/home/david/compile-cuberite/cuberite` @ `3ec51bcb9f9277e955ec400063c88d54e7ae690b`。
> 全部结论来自**源码 + 四个架构的反汇编 + 运行中的 x86-64 服务器实测**。

---

## 0. 结论速览

| 能力 | 能否做到 | 手段 |
|---|---|---|
| 拿到 `m_FireworkItem` 对象 | ✅ | `Item.m_FireworkItem`（tolua 变量，get+set 都在） |
| 知道 C++ 类型名 | ✅ | `tolua.type(x) == "cFireworkItem"` |
| 读 `m_Type`（爆炸形状字节） | ✅ | `tolua.cast(x,"cItem").m_ItemCount` |
| 读 `m_HasFlicker` / `m_HasTrail` | ✅ | 同上 `.m_ItemType` 的两个字节 |
| 读 / 写 `m_FlightTimeInTicks` | ✅ | 同上 `.m_ItemDamage` |
| 数出两种颜色表的**元素个数** | ✅ | `cCuboid` 视图重构 `std::vector<int>` 头指针 |
| 读出颜色的**具体数值** | ❌ | 无 `std::vector<int>` 绑定访问器，Lua 不能解引用 |
| 写入 / 构造颜色 | ❌ | 无法构造 `cFireworkItem` |
| **整体拷贝**（含两组颜色） | ✅ | `Dst.m_FireworkItem = Src.m_FireworkItem`（C++ 赋值，与 ABI 无关） |
| 调用 `cFireworkItem` 的方法 | ❌ | 该类**没有任何绑定方法**，也没有全局类表 |
| `tolua.cast` 转到**未注册**类型 | 💥 | **SIGSEGV，整服崩溃**（四个架构同一序列） |

一句话：**能整体搬运，能读写三个标量字段，能数出颜色个数；颜色值本身不可见。**

---

## 1. 它到底是什么（源码为准）

`src/WorldStorage/FireworksSerializer.h`：

```cpp
class cFireworkItem
{
public:
	cFireworkItem(void) :
		m_HasFlicker(false), m_HasTrail(false), m_Type(0), m_FlightTimeInTicks(0) {}

	inline void CopyFrom(const cFireworkItem & a_Item) { /* 逐成员赋值 */ }
	...
	bool m_HasFlicker;              // +0x00
	bool m_HasTrail;                // +0x01
	NIBBLETYPE m_Type;              // +0x02  ← 1 字节！NBT "Type"（爆炸形状 0..4）
	short m_FlightTimeInTicks;      // +0x04
	std::vector<int> m_Colours;     // +0x08
	std::vector<int> m_FadeColours; // +0x08 + sizeof(std::vector<int>)
};
```

`src/Item.h`（成员声明顺序即内存顺序）：

```cpp
	short          m_ItemType;      // +0x00
	char           m_ItemCount;     // +0x02
	short          m_ItemDamage;    // +0x04
	cEnchantments  m_Enchantments;  // +0x08
	AString        m_CustomName;
	AStringVector  m_LoreTable;
	int            m_RepairCost;
	cFireworkItem  m_FireworkItem;  // LP64: +0x78   ILP32: +0x48
	cColor         m_ItemColor;
```

**`m_Type` 不是物品 ID**：它是 NBT 的 `Fireworks.Explosions[].Type`（0=小球 1=大球 2=星形 3=苦力怕 4=爆裂），
由 `cFireworkItem::ParseFromNBT` 从 NBT 读入、`WriteToNBTCompound` 写出。**合成路径不会填它**。

上游文档状态：只有 `cFireworkEntity:GetItem` 的说明里提了一句，`API/_undocumented.lua` 把它登记为
`cItem` 的未文档化成员变量；`cuberite_api` 的 `cItem` 卡片完全看不到它。

---

## 2. 绑定方式（tolua++）

`src/Bindings/Bindings.cpp`：

```cpp
static int tolua_get_cItem_m_FireworkItem(lua_State* tolua_S)
{
  ...
  tolua_pushusertype(tolua_S, (void*)&self->m_FireworkItem, "cFireworkItem");
  return 1;
}
static int tolua_set_cItem_m_FireworkItem(lua_State* tolua_S)
{
  ...
  self->m_FireworkItem = *((cFireworkItem*) tolua_tousertype(tolua_S,2,nullptr));
  return 0;
}
...
tolua_variable(tolua_S,"m_FireworkItem",
               tolua_get_cItem_m_FireworkItem, tolua_set_cItem_m_FireworkItem);
```

- getter 只是把 `&self->m_FireworkItem` 打上 `"cFireworkItem"` 标签推出去；
- setter 是**整结构赋值**（编译器生成的 `cFireworkItem::operator=`）。

运行时（x86-64 实测）：

```lua
cItem[".get"] = cItem[".set"] = { m_CustomName, m_Enchantments, m_FireworkItem,
                                  m_ItemColor, m_ItemCount, m_ItemDamage,
                                  m_ItemType, m_Lore, m_LoreTable, m_RepairCost }
tolua.type(it.m_FireworkItem)      --> "cFireworkItem"
_G.cFireworkItem                   --> nil        -- 没有全局类表，也没有任何方法
it.m_FireworkItem == it.m_FireworkItem --> true   -- 按指针缓存的 userdata（tolua_ubox）
it.m_FireworkItem.AnyRealMember    --> nil        -- 读不到真实成员
```

`debug.getregistry()` 有 227 个已注册类型名，含 `cFireworkItem` 与 `const cFireworkItem`。

---

## 3. 核心手法：`tolua.cast` 重解释（type punning）

`cFireworkItem` 没有方法，但 `tolua.cast(userdata, T)` **只按名字重新打标签，不做运行期校验**。
把载荷当成 `cItem` 看，前 6 个字节正好落在 cItem 的前三个标量上：

| 表达式 | 读到的载荷字段 | 宽度 |
|---|---|---|
| `View.m_ItemType` | `{m_HasFlicker, m_HasTrail}`（二字节目） | short |
| `View.m_ItemCount` | `m_Type`（爆炸形状） | signed char |
| `View.m_ItemDamage` | `m_FlightTimeInTicks` | short |
| `View.m_Enchantments` 的地址 | `m_Colours` 本体 | — |

**注意** `View.m_ItemCount` 是按 **signed char** 读的（`movsbl` / `ldrsb`），值 ≥128 会变负数，
要用 `% 256` 还原。

### 3.1 独立验证：用 `cItem:IsEqual` 当预言机

`IsEqual` 内部比较 `m_FireworkItem.IsEqualTo(...)`，即整个载荷。于是：

```lua
local A = cItem(E_ITEM_FIREWORK_ROCKET, 1, 0)
local B = cItem(A)                       -- C++ 拷贝构造
A:IsEqual(B)                             --> true
tolua.cast(A.m_FireworkItem,"cItem").m_ItemDamage = 1234
A:IsEqual(B)                             --> false  ← 写入确实落在载荷里
A.m_ItemDamage, B.m_ItemDamage           --> 0, 0   ← 且不是外层 cItem 的字段
```

这条判据不需要偏移量知识，是本模块 `IsAvailable()` 自检的核心。

### 3.2 数颜色个数

`std::vector<T>` 的头是 `{begin, end, capacity}` 三个指针。`cCuboid` 恰好是两个 `Vector3i`
（各 12 字节：p1@+0，p2@+0x0C），而 `Vector3i` 的 `.x/.y/.z` 可直接读 —— 于是六个 32 位字
把小端 64 位指针拆开，拼回去就能算 `(end-begin)/4`。

`m_FadeColours` 在 `m_Colours + sizeof(std::vector<int>)`，用 `cCuboid.p2` 每次前进 12 字节走过去
（LP64 走 2 步，ILP32 走 1 步）。

---

## 4. 跨架构验证（四个构建）

反汇编四个构建里的**同一批函数**（`tolua_get/set_cItem_m_FireworkItem` 及各成员 getter）：

| 项目 | x86-64 | aarch64 | armv6l | i386 |
|---|---|---|---|---|
| ABI | LP64 | LP64 | ILP32 | ILP32 |
| `offsetof(cItem, m_ItemType/Count/Damage)` | 0/2/4 | 0/2/4 | 0/2/4 | 0/2/4 |
| `offsetof(cItem, m_Enchantments)` | 8 | 8 | 8 | 8 |
| `offsetof(cItem, m_FireworkItem)` | 0x78 | **0x78** | 0x48 | **0x48** |
| `offsetof(cFireworkItem, m_Colours)` | 8 | 8 | 8 | 8 |
| `offsetof(cFireworkItem, m_FadeColours)` | 0x20 | **0x20** | 0x14 | **0x14** |
| `sizeof(std::vector<int>)` | 24 | 24 | 12 | 12 |
| `cCuboid::p2` | 0x0C | 0x0C | 0x0C | 0x0C |
| `tolua_pushusertype` 对未注册类型 | SIGSEGV | 同序列 | 同序列 | 同序列 |

**分界线是 ILP32 / LP64，不是 CPU 架构**：aarch64 与 x86-64 逐字节相同，i386 与 armv6l 逐字节相同。

关键指令：

```asm
; aarch64 (LP64) —— 偏移与 x86-64 完全相同
add  x1, x19, #0x78        ; &self->m_FireworkItem
ldrh w3,[x19]     / strh w3,[x2]        ; dst+0  (m_HasFlicker + m_HasTrail)
ldrb w3,[x19, #2] / strb w3,[x2, #2]    ; dst+2  (m_Type)
ldrsh w3,[x19,#4] / strh w3,[x2, #4]    ; dst+4  (m_FlightTimeInTicks)
add  x0, x20, #0x80                     ; dst+8     -> m_Colours
add  x0, x20, #0x98                     ; dst+0x20  -> m_FadeColours
add  x1, x19, #0x20                     ; src+0x20
add  x1, x19, #0xc                      ; cCuboid::p2

; armv6l (ILP32)
add  r1, r4, #72           ; &self->m_FireworkItem = 0x48
ldrh/ldrb/ldrsh            ; dst+0 / +2 / +4
add  r0, r4, #80           ; dst+8     -> m_Colours
add  r0, r4, #92           ; dst+0x14  -> m_FadeColours

; i386 (ILP32)
lea  0x50(%esi),%eax / lea 0x8(%edi),%ecx     ; dst+8    -> m_Colours
add  $0x5c,%esi      / add $0x14,%edi         ; dst+0x14 -> m_FadeColours

; 四个构建共同的崩溃路径
lua_getfield(L, LUA_REGISTRYINDEX, type) -> lua_pushstring(L,"tolua_ubox") -> lua_rawget(L,-2)
```

- 编译器对结构体前 8 字节的拷贝切法因架构而异（x86-64 / i386 是 `4B+2B`，aarch64 / armv6l 是 `2B+1B+2B`），
  但语义一致，都印证源码里 `{bool, bool, uchar}` + `short` 的布局。
- 载荷在 cItem 里的绝对位置（0x78 vs 0x48）**不影响我们**：地址由引擎自己的 getter 给出，我们只用**载荷相对偏移**。
- `m_Colours` 在四种 ABI 上都在载荷 +8；只有 `m_FadeColours` 随指针宽度变（+0x20 / +0x14）。

**结论**：标量读写与 `m_Colours` 计数在四种 ABI 上一致可用；
`m_FadeColours` 计数按 `sizeof(std::vector<int>)` 走 1 步还是 2 步（模块按"哪个候选读数合理"自动选择）。
`Copy` 是 C++ 赋值，与 ABI 完全无关。

> 构建来源：`https://download.cuberite.org/linux-{aarch64,i386}/Cuberite.tar.gz`
> （302 到 builds.cuberite.org 的 lastSuccessfulBuild），两者均 not stripped。
> aarch64 是 PIE、i386 是固定地址 EXEC，不影响符号偏移。

---

## 5. ⚠️ 崩溃与内存安全

### 5.1 `tolua.cast` 到未注册类型 = 整服 SIGSEGV（已复现，四架构同源）

x86-64 实测崩溃栈：

```
./Cuberite(_Z15PrintStackTracev+0x18)
./Cuberite(tolua_pushusertype+0x3e) [0x98365e]
./Cuberite(lua_rawget+0xd5)         [0x9465c5]
SIGSEGV: Segmentation fault
```

`tolua_pushusertype` 先 `luaL_getmetatable(L, type)`（未注册 → `nil`），紧接着
`lua_pushstring(L,"tolua_ubox"); lua_rawget(L,-2)` —— **对一个 nil 做 rawget**。
Lua 5.1 的 `lua_rawget` 直接 `hvalue(t)`（不做 api_check），而 nil 的 `value.gc` 是 NULL，
于是对近 0 地址解引用。四个构建里这段逻辑逐指令相同（`lua_getfield` → `lua_pushstring` → `lua_rawget`），
**同样必崩**。

触发语句就是 `tolua.cast(fw, "NoSuchType")`（同批次其它名字均在注册表中，可唯一归因）。

### 5.2 其它雷区

| 雷 | 说明 |
|---|---|
| `tolua.cast` 到**任意**已注册类型 | 无校验；`cast(x,"cPlayer")` 会成功，之后调用其方法就是任意内存读/崩服 |
| `tolua.takeownership(x)` | GC 会 `delete` 一个**指向 cItem 内部**的指针 → 双重释放 |
| 悬垂引用 | getter 只包地址、**不持有父 cItem**；`Player:GetEquippedItem().m_FireworkItem` 这类临时对象被 GC 后即悬垂 |
| 写 `View.m_Enchantments = ...` | 会把 `std::map` 写进 `std::vector<int>` 头部 → 后续拷贝/析构崩 |
| `cInventory:GetSlot(i)` 越界 | `invNumSlots` = 41（0..40）；实测 i=41..44 会返回**别的内存**当作 cItem，必须用常量封顶 |

### 5.3 本模块的防护

1. 每次 `tolua.cast` 前查 `debug.getregistry()[T]`，缺失就拒绝；
2. 所有 cast 包在 `pcall` 里；
3. `ReadVector` 对 vec 头做合理性校验（`cap>=end>=begin`、4 字节对齐、`<=4096`），不合理就返回 nil；
4. `IsAvailable()` 用 `cItem:IsEqual` 做**语义**自检（不只是"机制能用"）；
5. 任何一步失败 → 模块整体降级为不可用，调用方保持旧行为。

---

## 6. 端到端实测

用机器人 + **原始窗口点击包**驱动原版合成（mineflayer 的 minecraft-data 没有烟花配方；
`cRoot:Get():GetCraftingRecipes()` 返回的对象也没有任何绑定方法，`HandleFireworks` 只被未绑定的
`cCraftingRecipes::GetRecipe` 调用）：

1. `set_block` 放工作台（58）→ `mcc_container_open_at`；
2. 左键拿起火药 → 右键工作台格放 1 个 → 左键放回；玫瑰红染料同理；
3. 结果槽出现 **Firework Star**（真实合成）；
4. 关闭窗口，物品回到背包。

服务器侧读取：

```
slot 34: type=402 count=1  <<<< FIREWORK
    fw.Type=0  Flight=0  Colours.COUNT=1  Fade=0
    begin=140098081204640 end=140098081204644 cap=140098081204644
```

颜色个数 **1**（那一份玫瑰红染料），`end-begin == 4`、`cap == end` —— 指针重构正确。

决定性因果验证：

```
对照（新火箭，自己没数据）        : Colours=0  CreateProjectile -> 0
克隆（rocket.m_FireworkItem = star.m_FireworkItem）
                                  : Colours=1  CreateProjectile -> 665  ✅
克隆后再写 FlightTimeInTicks = 30  : Flight=30    CreateProjectile -> 666  ✅
```

---

## 7. 复现步骤

```lua
-- 0) 先确认类型已注册，否则 tolua.cast 会崩服
local Reg = debug.getregistry()
assert(Reg["cFireworkItem"] and Reg["cItem"] and Reg["cCuboid"])

-- 1) 读标量（注意 m_Type 走 m_ItemCount）
local Item = cItem(E_ITEM_FIREWORK_ROCKET, 1, 0)
local View = tolua.cast(Item.m_FireworkItem, "cItem")
print(View.m_ItemCount % 256, View.m_ItemDamage)
print((View.m_ItemType % 256) ~= 0, (math.floor(View.m_ItemType / 256) % 256) ~= 0)

-- 2) 数颜色（LP64：再取一次 p2；ILP32：就是 c1.p2）
local c1 = tolua.cast(View.m_Enchantments, "cCuboid")
local function ptr(lo, hi)
  if lo < 0 then lo = lo + 4294967296 end
  if hi < 0 then hi = hi + 4294967296 end
  return hi * 4294967296 + lo
end
print("Colours:", (ptr(c1.p1.z, c1.p2.x) - ptr(c1.p1.x, c1.p1.y)) / 4)

-- 3) 整体克隆（把有颜色物品的数据搬到新火箭上）
local Rocket = cItem(E_ITEM_FIREWORK_ROCKET, 1, 0)
Rocket.m_FireworkItem = <有颜色的烟花物品>.m_FireworkItem
local W = cRoot:Get():GetDefaultWorld()
print(W:CreateProjectile(0, 80, 0, cProjectileEntity.pkFirework, nil, Rocket))  -- 0 => 非 0
```

---

## 8. 一句话总结

`m_FireworkItem` 是"上游只留了一条缝、缝后面是整个结构体"的地方：
tolua 按 `cFireworkItem` 注册了类型却不给它任何方法，于是 `tolua.cast` 重解释成了唯一入口 ——
能读写三个标量、能数出颜色个数、能整体搬运（含颜色），但读不到颜色数值；
而且**一次不小心的 `tolua.cast` 就能让整台服务器 SIGSEGV，这在四个构建上一模一样**。
