-- Info.lua

-- Implements the g_PluginInfo standard plugin description

g_PluginInfo =
{
	Name = "VanillaFeatureComplement",
	Version = "5",
	Date = "2026-10-01",
	Description = [[Re-implements missing vanilla Minecraft features in Cuberite: map zoom-out & cloning, end platform generation, elytra powered flight, sleeping clears the weather, shields, player-death XP / off-hand drops, village location detection, and contents for the chests village prefabs place but cannot stock.]],

	Commands =
	{
		["/locate"] =
		{
			Permission = "",
			HelpString = " <StructureType> - shows the nearest structure of that type",
		},
	},

	ConsoleCommands =
	{
		["locate"] =
		{
			HelpString = " <StructureType> <x> <z> [radius] [world] - nearest structure of that type",
		},
	},

	Permissions =
	{
	},
}
