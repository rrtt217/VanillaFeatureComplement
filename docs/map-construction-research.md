# 插件能否构造出新的地图

> 结论基于本机 C++ 源码（`/home/david/compile-cuberite/cuberite/src`）、
> 运行中的服务器（`cuberite_api` + `execute_lua`）与未 strip 的二进制符号三方核对。

## 0. 结论

**不能凭空构造。** `cMapManager::CreateMap` 没有绑定到 Lua，而 tolua 内省那套工具箱也够不着它 ——
它是**成员函数**，那套方法只能读写已绑定类的**成员变量**，不能调用未绑定的行为。

全代码库里 `CreateMap` **只有一个调用点**：`Items/ItemEmptyMap.h:44`，即
`cItemEmptyMapHandler::OnItemUse`（玩家拿空地图右键）。那次点击是包驱动的，
插件无法合成它。

**所以在不给服务端打补丁的前提下，插件无法主动创建新地图。**

---

## 1. 决定：不改变地图缩放 / 克隆的现有行为

本分支记录的决定：

- **不引入**"合成空地图 → 右键"的两步流程（§3 那条路能给真·新 ID，但改变玩家操作语义）；
- **不做**孤儿地图 ID 回收（§5）；
- **保留**现有 fallback：`map_zoomout.lua` 的 `BuildZoomedOutMap` 在 `CreateMap` 不可用时返回
  `nil`，调用方改为就地缩放原地图；
- **保留**现有 feature-detect：在绑定了 `CreateMap` 的服务端上自动走正确路径。

理由见 §6。

---

## 2. 为什么 `CreateMap` 够不着

| 证据 | 内容 |
|---|---|
| 运行时 | `cMapManager` 类表里只有 `DoWithMap`（+ tolua 元方法）；`cMapManager.CreateMap == nil`；`cMapManager[".get"]` 是**空表** |
| 源码 | `MapManager.h` 里 `// tolua_end` 紧跟 `public:`，所有成员落在导出区之外；`Bindings/ManualBindings.cpp:4657` 只手写注册了 `DoWithMap` |
| 全树 grep | `CreateMap` 只有三处：声明（`MapManager.h:40`）、定义（`MapManager.cpp:92`）、**调用（`ItemEmptyMap.h:44`）** |

同理 `cMapManager::GetMapData` 也没绑定，Lua 侧只能通过 `DoWithMap(ID, Callback)` 间接拿到 `cMap`。

---

## 3. 唯一能产生真·新地图的路径

```cpp
// Items/ItemEmptyMap.h —— the ONLY caller of CreateMap in the whole codebase
auto NewMap = a_World->GetMapManager().CreateMap(CenterX, CenterZ, DEFAULT_SCALE);
if (NewMap == nullptr)
{
	return true;
}
a_Player->ReplaceOneEquippedItemTossRest(cItem(E_ITEM_MAP, 1, static_cast<short>(NewMap->GetID() & 0x7fff)));
```

- 点击来自 `cClientHandle::HandleRightClick` / `HandleUseItem`，插件**无法合成**。
- **但插件能接住结果**：`HOOK_PLAYER_USED_ITEM` 在 `OnItemUse` 之后、同一 tick 触发，
  此时 `Player:GetEquippedItem().m_ItemDamage` 已经是新的地图 ID。
- 空地图玩家自己就能合成：`crafting.txt:214  map: EmptyMap = Paper ×8 + Compass`。

所以这条路的形态是"两步"：合成空地图 → 右键 → 插件在 `HOOK_PLAYER_USED_ITEM` 里用
`DoWithMap(NewID, ...)` 把旧图按比例写进新地图。**决定不采用**（§1、§6）。

---

## 4. 走不通的路

1. **直接调用 `CreateMap`** —— §2。
2. **自己编一个 ID 塞进物品的 `m_ItemDamage`** —— `cItemMapHandler::OnUpdate` 在
   `GetMapData(id) == nullptr` 时**静默 return**，地图什么都不显示。
3. **从 Lua 构造 `cMap`** —— 没有绑定构造函数（`nm` 里没有 `tolua_AllToLua_cMap_new`）；
   而且物品→地图的查找是 `GetMapData(m_ItemDamage)`，即管理器 vector 的下标，
   游离的 `cMap` 永远查不到。
4. **合成 / 发射器 / 容器 / 其他物品处理器** —— `CreateMap` 只有一个调用点，别的路径都不存在。

---

## 5. 能"回收"，但不能算"新建"

```cpp
cMap * cMapManager::GetMapData(unsigned int a_ID)
{
	if (a_ID < m_MapData.size()) { return &m_MapData[a_ID]; }
	return nullptr;
}

cMap * cMapManager::CreateMap(int a_CenterX, int a_CenterY, unsigned int a_Scale)
{
	cCSLock Lock(m_CS);
	if (m_MapData.size() >= 65536) { LOGWARN("Could not craft map - Too many maps in use"); return nullptr; }
	cMap Map(static_cast<unsigned>(m_MapData.size()), a_CenterX, a_CenterZ, m_World, a_Scale);
	m_MapData.push_back(Map);
	return &m_MapData[Map.GetID()];
}
```

- **ID = 创建时的 vector 下标**，稠密、顺序、上限 65536。
- `m_MapData` **从无 erase**：只在 `CreateMap` / `LoadMapData` 里 `push_back`，
  卸载时 `clear`。所以 **ID 永不回收、永不重用**。
- 插件可以用 `DoWithMap` 二分出当前数量 N、枚举 `0..N-1`，找一张"主人不在了"的图，
  用 `SetScale` / `SetPosition` / `SetPixel` / `Resize` 改写成"新"地图再发出去。
  **今天就能用、不需要玩家操作**，但它抢占的是**别人的 ID**（见 §6）。

---

## 6. 为什么不改变行为

1. **回收路径并没有修好那个毛病，只是把它挪了个位置。** 因为 `m_MapData` 从不 erase，
   没有任何 ID 是"空闲"的 —— 只有"主人不在了"的。两张图共享同一 ID 时，任何一方改动都会串到另一方，
   而这**正是当前 fallback 的毛病**（README 里"缩放后的地图复用原编号，所以该图的每份副本会一起缩放"）。
   回收等于换一个更隐蔽的方式踩同一个坑，还多了一条"可能覆盖到别人正在用的地图"的风险。

2. **两步流程虽然能给真·新 ID，但代价不止是 UX。** 引擎的 `CreateMap` 用 `DEFAULT_SCALE = 0`、
   以**玩家当前位置**为中心建图；插件随后要覆盖 scale / position / 全部像素。中间客户端可能已经收到
   一帧错误的地图数据；而且玩家每次缩放都要多一次右键。

3. **现有 fallback 是"行为可预测"的。** 它的限制是引擎能力的**直接映射**，文档已经写明。
   在引擎不暴露 `CreateMap` 的前提下，任何"造新图"的方案都是**用不同方式绕过同一个限制**，
   而不是消除它 —— 而绕过的代价（抢占 ID / 改变操作语义）比限制本身更糟。

4. **保留 feature-detect 已经把上游修好的情况覆盖了。** 一旦上游绑定 `CreateMap`，
   现有代码自动走正确路径，不需要再改。

**结论：维持现状，等上游绑定。**

---

## 7. 顺带修掉的一个真 bug

调研过程中发现 `EvaluateEvent` **完全没有建模 `E_ITEM_EMPTY_MAP`**：

- 已核对：`shield.lua` 里 `EMPTY_MAP` 零出现、数值 `395` 零出现，不在任何 item 表里；
- 于是它落到函数末尾的 `return false, true`，判定"这次右键没被消耗"；
- 但引擎**确实消耗了**（空地图被换成填充地图），槽位真的变了；
- **后果：玩家用空地图时，副手盾牌会被错误举起。**

已修：在 `EvaluateEvent` 里加 `E_ITEM_EMPTY_MAP → true, true`，并在
`tests/shield_test.lua` 的 A 段加两条断言（空手瞄准 / 瞄准方块）。

> 验证方式：把新分支临时改成 `if false and ...` 后重跑，**恰好这两条失败**
> （`raised=true wanted=false`），恢复后 600 passed —— 证明测试不是空转。

这也是 `docs/shield-consumption-oracle.md` 里那个消耗探针**第一次真正用起来就抓到的漏项**：
"槽位确实变了、但手写模型说没消耗"这一类情形。空地图是它的第一个实例。

---

## 8. 附带情报（做地图功能会用上）

- **手持地图会更新**：`cInventory::UpdateItems()` 每 tick 只对 `GetEquippedItem()` 调 `OnUpdate`
  → `cItemMapHandler::OnUpdate` 做 `UpdateRadius(player, 128)` + `UpdateClient(player)`，
  再由 `cMap::Tick()`（世界 tick → `cMapManager::TickMaps`）把数据推给客户端。
  **只有主手槽会 tick**，副手和箱子里的地图不会。
- `cMap` 的 Lua 可写面：`SetPixel` / `GetPixel` / `Resize` / `SetScale` / `SetPosition` /
  `GetWidth` / `GetHeight` / `GetPixelWidth` / `GetNumPixels` / `GetID` / `GetCenterX` /
  `GetCenterZ` / `GetWorld` / `GetName` / `GetDimension`。
- 地图上限 65536；满了 `CreateMap` 返回 `nullptr` 并打
  `Could not craft map - Too many maps in use`。
- `cMapManager::DoWithMap(ID, Callback)` 返回 `bool`（图不存在时 `false`），
  是 Lua 侧判断"某个 ID 是否存在"的唯一手段 —— 二分即可求出当前地图总数。
