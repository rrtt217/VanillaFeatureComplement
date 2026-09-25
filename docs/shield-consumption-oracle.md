# 用 "USED_ITEM + 槽位差分" 取代 EvaluateEvent：可行性与兜底需求

> 分支 `research/shield-consumption-oracle`，基线 `main@b78b3a1`。
> 结论基于本机 C++ 源码（`/home/david/compile-cuberite/cuberite/src`）逐行核对。

## 0. 结论

**不可行。** 差分只能给出一个方向的结论：

| 差分结果 | 能推出的结论 |
|---|---|
| 槽位**变了** | 几乎肯定消耗了（但见 §4） |
| 槽位**没变** | **什么也推不出** —— 没消耗 / 消耗了但不碰物品 / 碰了但被附魔抵消 |

而当前逻辑（`EvaluateEvent` 149 行 + `GetTargetedBlock` 及其块工具 103 行，共 **252 行**）
存在的**唯一理由**就是"没变"这个方向：它用一个**对 handler 行为的模型**来回答
"这个物品打在这个方块上会不会被消耗"，这个模型对创造模式和附魔天然免疫。

所以：

- 252 行 **一行都不能删**；
- 差分本身还要新增代码（USING_ITEM 快照 + 注册 HOOK_PLAYER_USED_ITEM + 比较）；
- **净效果是代码变多**，换来一个只在"生存模式 + 无耐久附魔"下才触发的快路径。

---

## 1. 提议回顾

插件需要在 `HOOK_PLAYER_USING_ITEM` 里判断"主手物品会不会消耗这次右键"，
以便决定副手盾牌是否举起。引擎不给这个信号：

- `ClientHandle.cpp`：`ItemUseable = !spectator`，生存玩家对着空气/非可用方块右键一律走
  `ItemHandler.OnItemUse`，由 handler 自己决定做不做事；
- `OnItemUse` 返回 `void`（源码里还留着 `// TODO: delete OnItemUse bool return`）；
- `HOOK_PLAYER_USED_ITEM` 在 `OnItemUse` **之后无条件**触发
  （`if (!UsingItem(...)) { OnItemUse(...); UsedItem(...); }`），不是消耗信号。

提议 ：在 USING_ITEM 拍一张主手槽快照，在 USED_ITEM（同 tick、OnItemUse 之后）再拍一张，
用差异判断是否消耗，从而删掉 `EvaluateEvent` 和 `GetTargetedBlock`。

---

## 2. 反例一：创造模式 —— 状态机在创造模式下会**完全失效**

证据链（三处叠加）：

**2.1 `cPlayer::UseEquippedItem(short)` 直接提前返回**

```cpp
void cPlayer::UseEquippedItem(short a_Damage)
{
	// No durability loss in creative or spectator modes:
	if (IsGameModeCreative() || IsGameModeSpectator())
	{
		return;
	}
	UseItem(cInventory::invHotbarOffset + m_Inventory.GetEquippedSlotNum(), a_Damage);
}
```

**2.2 每个 handler 自己也有创造模式分支**

`src/Items/*.h` 里 **20 个文件**带 `IsGameModeCreative` 判断：

```
ItemBoat        ItemBottle      ItemBow        ItemBucket     ItemChorusFruit
ItemEndCrystal  ItemEyeOfEnder  ItemFood       ItemFoodSeeds  ItemGoldenApple
ItemItemFrame   ItemLighter     ItemLilypad    ItemMilk       ItemMinecart
ItemPainting    ItemPotion      ItemSoup       ItemSpawnEgg   ItemThrowable
```

以打火石为例（`ItemLighter.h`）：

```cpp
if (!a_Player->IsGameModeCreative())
{
	if (m_ItemType == E_ITEM_FLINT_AND_STEEL)
	{
		a_Player->UseEquippedItem();
	}
	else  // Fire charge.
	{
		a_Player->GetInventory().RemoveOneEquippedItem();
	}
}
```

**后果**：创造模式下点燃一堆火 / 舀一桶水 / 吃一个金苹果 / 扔一个雪球 ——
这些**都消耗了这次右键**，但物品槽一个字节都没动。差分一律判定"没消耗"，
于是副手盾牌被错误举起。创造模式恰恰是玩家最常测试机制的场合。

---

## 3. 反例二：耐久附魔 —— 打火石和锄头会**经常**破坏状态机

**3.1 耐久损失是一次二项分布抽样**

`cPlayer::UseItem(int a_SlotNumber, short a_Damage)`：

```cpp
// Ref: https://minecraft.wiki/w/Enchanting#Unbreaking
unsigned int UnbreakingLevel = Item.m_Enchantments.GetLevel(cEnchantments::enchUnbreaking);
double chance = ItemCategory::IsArmor(Item.m_ItemType)
	? (0.6 + (0.4 / (UnbreakingLevel + 1))) : (1.0 / (UnbreakingLevel + 1));

// When durability is reduced by multiple points
// Unbreaking is applied for each point of reduction.
std::binomial_distribution<short> Dist(a_Damage, chance);
short ReducedDamage = Dist(GetRandomProvider().Engine());

if (m_Inventory.DamageItem(a_SlotNumber, ReducedDamage))
{ ... }
```

**3.2 抽到 0 就直接返回，连槽位包都不发**

`cInventory::DamageItem`：

```cpp
if (a_Amount <= 0)
{
	return false;          // 没有 SendSlot，物品纹丝不动
}
...
if (!Grid->DamageItem(GridSlotNum, a_Amount))
{
	SendSlot(a_SlotNum);   // 只有真的扣了才推送
	return false;
}
```

**3.3 概率有多高**

`chance = 1 / (等级 + 1)` 是**施加**伤害的概率，所以 `P(ReducedDamage == 0)`：

| 耐久等级 | P(这次成功使用完全不掉耐久) |
|---|---|
| I | 1/2 |
| II | 2/3 |
| III | 3/4 |

**这正好命中你点名的两个物品**：

- `ItemLighter.h`：打火石成功点燃后调 `a_Player->UseEquippedItem()`（=1 点伤害）；
- `ItemHoe.h:66`：耕地成功后调 `a_Player->UseEquippedItem()`。

（弓 `ItemBow.h:93`、剪羊毛、破坏方块也走同一个 `UseItem` 二项抽样，只是不属于本判定路径。
  打火石和锄头之所以致命，是因为它们**恰好是 EvaluateEvent 需要判定的那类"对着方块右键"**。）

即：**生存模式 + 耐久 III 的打火石，75% 的成功使用会被差分判成"没消耗"。**
这不是边缘情况，是主路径。

> 顺带记录一个观察（与本议题相邻，值得单独确认）：wiki 的口径是
> P(不掉耐久) = 1/(等级+1)，即 P(掉耐久) = 等级/(等级+1)；
> 而这里的 `chance` 是 P(掉耐久) = 1/(等级+1)。等级 1 时两者一致（都是 1/2），
> **等级 2/3 时本构建明显比原版更"抗用"**。是否是上游 bug 需要单独验证，
> 但无论哪个公式，`ReducedDamage == 0` 都是常见事件，结论不变。

---

## 4. 补充反例：即使槽位"变了"，也不绝对可靠

差分的正向信号同样不是公理：

- 同一 tick 里**别的来源**也可能改这个槽位并推送：另一个插件的操作、漏斗/容器搬运、
  拾取物合并进手持槽、客户端与服务端的库存同步；
- 玩家在这些事件之间切换快捷栏槽位，快照与比较若跨了这一下就会错位。

所以要把它当"几乎肯定"而不是"确定"。

---

## 5. 为什么兜底无法缩小 —— 直接回答"还剩多少要兜底"

**全部 252 行，一行都不能删。** 理由是一个简单的逻辑不对称：

```
差分 = "变了"  -> 消耗      （正向）   ← 只在生存 + 无附魔时可用
差分 = "没变"  -> 未知      （无结论） ← 正是 EvaluateEvent 负责的那一格
```

`EvaluateEvent(Player, Type, BlockType)` 的每一行都在回答"给定物品类型 + 给定瞄准的方块类型，
这个 handler 会不会消耗"。它对**创造模式**和**耐久附魔**一无所知——也不需要知道，
因为它建模的是 handler 的分支逻辑，而不是处理后的副作用。

一旦差分说"没变"，调用方必须回到 `EvaluateEvent` 才能得到答案；
而 `EvaluateEvent` 又需要 `GetTargetedBlock` 把 `(-1,255,-1)` 空气哨兵解析成真实方块类型
（客户端在同一次右键的次要事件里发的就是这个哨兵）。两者是一根链条，拆不开。

**净代码变化是增加**：多一个 USING_ITEM 快照、多一个 `HOOK_PLAYER_USED_ITEM` 注册、
多一份每玩家状态、多一段比较逻辑；删掉 0 行。

---

## 6. 那这个 oracle 还有什么用 —— 当 EvaluateEvent 的测试预言机

把方向反过来就值钱了：**不要用它替代 `EvaluateEvent`，用它去验证 `EvaluateEvent`。**

在**生存模式 + 无耐久附魔**这个子集里，差分是可信的。于是：

1. 照常运行 `EvaluateEvent` 得到 `Consumed`；
2. 同时做槽位差分得到 `Observed`；
3. 只在两者不一致时打一条 debug 日志（含物品类型、方块类型、模式、附魔）。

任何一条不一致都是 **`EvaluateEvent` 的 bug 报告**——这正好补上了它现在最大的弱点：
它是手写的 handler 行为模型，而 `tests/shield_test.lua` 是 mock 驱动的，
mock 的期望值同样来自人的理解，属于用模型验证模型。

实现成本实测：`shield.lua` +约 105 行（含解释性注释）、`main.lua` +6 行、
测试 +约 150 行；且只在 `[Debug] EnableDebugLog=1` 时才注册钩子，
关闭时连快照都不记。收益是给 252 行的模型找到现实反例，
而不是拿一个已知会错 75% 的信号去替换它。

---

## 7. 什么时候值得重新考虑

- 上游给出"这次 OnItemUse 到底做没做事"的信号（源码里已经有
  `// TODO: delete OnItemUse bool return, delete onCancelRightClick` 的意图）；
- 或者 `cItemHandler` / `OnItemUse` 被绑定到 Lua，能直接问同一个谓词 ——
  注意这属于**行为**，tolua 内省（§13）够不着：那套工具只能读写**已绑定类的成员变量**，
  不能调用未绑定的虚函数。

在那之前，`EvaluateEvent` + `GetTargetedBlock` 是唯一正确的实现，
代价就是 252 行 —— 这是引擎缺口的成本，不是实现不够聪明。
