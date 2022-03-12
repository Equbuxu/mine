# An advanced mining program for ComputerCraft Turtles

This program is capable of mining an arbitrary area while removing lava, automatically refueling itself, bringing the mined items into one place, and more (no auto torches though sadly).

## Basic usage

1. Run `pastebin get 7uHd9pPx mine`. Run `mine`. 
1. On startup, the program shows a bunch of info, such as fuel level, slots used for various items, etc.
1. By default, three slots are assigned: Chests, Coal and Cobblestone.
Chests are required since they are used to drop off mined items, but the cobblestone and coal slots can be left empty.
The turtle will store collected coal and cobblestone in those slots and use them when necessary.
1. Below that, you will see a list of programs. 
You can run `help <program>` to get a description of any specific program.
1. Let's assume you want the turtle to branch mine. 
Type `branch 5 20`. 
The turtle should start mining a 20-block long tunnel in the direction it is facing. 
The tunnel will have 5-block branches going to the left and right.
Note that the order it mines the blocks in might seem a bit strange
1. While mining, the turtle will go through ore veins without going further than 5 blocks from the area it's mining.
1. The turtle will place chests near the place where it has started mining.

**Currently existing programs:**

- `help <program>` - 
display info about the chosen program
- `sphere <diameter>` - 
Mine a sphere of diameter `<diameter>`, starting from it's bottom center
- `cube <left> <up> <forward>` - 
Mine a cuboid of a specified size. Use negative values to dig in an opposite direction
- `rcube <leftR> <upR> <forwardR>` - 
Mine a cuboid centered on the turtle. Each dimension is a "radius", so typing `rcube 1 1 1` will yield a 3x3x3 cube
- `branch <branchLen> <shaftLen>` - 
Branch-mining. `<branchLen>` is the length of each branch, `<shaftLen>` is the length of the main shaft

## Configuration

The `mine.lua` file contains a config section at the top. You may edit this section to change the turtle's behaviour.

Here is the default state of the config, with comments explaning each setting:
```lua
cfg.localConfig = {
	--if true, the program will attempt to download and use the config from remoteConfigPath
	--useful if you have many turtles and you don't want to change the config of each one manually
	useRemoteConfig = false,
	remoteConfigPath = "http://localhost:33344/config.lua",
	--this command will be used when the program is started as "mine def" (mineLoop overrides this command)
	defaultCommand = "cube 3 3 8",
	--false: build walls/floor/ceiling everywhere, true: only where there is fluid
	plugFluidsOnly = true,
	--maximum taxicab distance from enterance point when collecting ores, 0 = disable ore traversal
	oreTraversalRadius = 5,
	--layer mining order, use "z" for branch mining, "y" for anything else
	--"y" - mine top to bottom layer by layer, "z" - mine forward in vertical slices
	layerSeparationAxis="z",
	--false: use regular chests, true: use entangled chests
	--if true, the turtle will place a single entangled chest to drop off items and break it afterwards.
	--tested with chests from https://www.curseforge.com/minecraft/mc-mods/kibe
	useEntangledChests = false,
	--false: refuel from inventory, true: refuel from (a different) entangled chest
	--if true, the turtle won't store any coal. Instead, when refueling, it will place the entangled chest, grab fuel from it, refuel, and then break the chest.
	useFuelEntangledChest = false,
	--true: use two chuck loaders to mine indefinitely without moving into unloaded chunks. 
	--This doesn't work with chunk loaders from https://www.curseforge.com/minecraft/mc-mods/kibe, but might work with some other mod.
	--After an area is mined, the turtle will shift by mineLoopOffset and execute mineLoopCommand
	--mineLoopCommand is used in place of defaultCommand when launching as "mine def"
	mineLoop = false,
	mineLoopOffset = {x=0, y=0, z=8},
	mineLoopCommand = "rcube 1 1 1"
}
```
