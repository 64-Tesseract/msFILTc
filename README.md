# A Lua compiler for the [Micro Subframe FILT Computer](https://powdertoy.co.uk/Browse/View.html?ID=2908656)

Please post issues with the script on GitHub, and issues with the computer itself in the save comments.
Here is a """simple""" explanation of how to use the script, and you can view some demo programs in the `demos` folder.

## Usage
### Loading
First, create a plaintext file with one command or comment per line, which will serve as the source code for the compiler. Open the TPT console with the ~ key and run the `programmer.lua` script, for example:
```
dofile("C:/Users/User/Downloads/programmer.lua")
```
Note that you can use either `/` or `\\` between directories.

Then, to select a script using the file browser, type:
```
open_file_gui("C:/Users/User/Downloads/")
```
The path can point to a folder with computer assembly (but doesn't have to) - again, you can use either `/` or `\\`. Simply click on folders (blue) to open them, and on script file to compile it. The newly generated code should load in the computer automatically, but note that you need to reload the save to compile a new program.

### Commands & Arguments
You can see the available commands in the `codes` table at the top of the script. Commands are parsed with unique argument counts signified by the second byte in the `FILT` code minus one (for example, `0x2500000f` will run the `0xf` instruction with 5-1=4 arguments).

Arguments are very versatile - they may represent a raw value, an address to read or write from, a goto tag, or even a variable defined in the compiler. For a raw value, simply type the value like `69`.

When it comes to printing hard-coded text, you may join up to 3 characters to be printed simultaneously by the default ASCII module, which is done by allocating byte pairs per 1 character. To use a single character as an argument, just enter it in quotes: `"a"`. To combine multiple characters, separate them with commas as such:
```
copy "a","b","c" 0@io
```
  
While this is more of an effort to type, it allows easier joining of illegal characters (commas, spaces, and newlines), which need to be entered numerically, like `"H","i",10`. This is purely a QoL feature so you don't need to look up ASCII codes for everything you want to print, and I don't recommend using it for anything other than that.

To use an address as an argument, see the `addrs` table below the `codes` table. Type an index followed by `@` and the name of the address range; `420@ram` for instance, which will make the computer refer to `FILT` #420 in the RAM block - addresses are explained further below.

### Compiler Variables
Variables may be defined anywhere in a script, but for clarity should be listed at the start. To store a constant in the compiler and replace all instances of it later, write a new line starting with `$`, then the name of the variable, and its value:
```
$printer 0@io
copy "H","i" $printer
```
The value in variables may be any argument, even an address to be parsed later.

ROM constants are similar to variables, except their values are appended to the end of the physical program and actively read when requested. While marginally slower, this may be useful for finding and editing script constants in-game without having to recompile all the code. The syntax is the same as compiler variables, except with a `?`:
```
?const 727
copy ?const 16@ram
```
Finally, there are immutable "hard-coded variables", which are specific addresses for the computer like operation outputs. These can be found in the `haddr` table. Simply write its name in place of a variable to access it:
```
incr addout
copy incrout 64@ram
```

### Goto
Goto tags work differently to my previous computers, as they are defined on their own line with a `:` in front of them, above a line of code. To goto them, simply use their name (including the `:`) as an argument:
```
:loop
-- Do something
goto :loop
```

### Addresses
Addresses are a volatile feature, but can be very useful if used correctly. If the `0x10000000` bit is not set, then the computer will parse the value as an address and return the value at said address. Normally, reading from RAM would not modify the address bit, and as such it would be impossible to read or write the value of the address itself, so I introduced "instruction read/write modes" to modify the address bit. These are used by combining commands and any number of keywords with commas:
```
copy,opRA incrout 64@ram
```
This line will use the incrementer output as an address to find a value, and then copy it into RAM, rather than copying the incremented value itself. Modes can be found with short descriptions in the `cmdrw` table.

It is important to note that having an address refer to itself, directly or indirectly, will result in an infinite loop and the computer stalling.

### IO Modules
IO modules are easy to use in code, but difficult to design hardware for. The IO bus has been designed to work as similarly to RAM as possible, where one can read and write to individual modules in the same way as RAM addresses:
```
copy 9@io 0@io
```
To set up a port along the IO bus, copy an existing port (or one of the examples from the left corner of the save), and paste it in line with the bus. Do not paste it _over_ the bus, but rather in an empty spot in line with it - this is because the bus needs to have empty gaps in the `FILT` rows, and pasting empty space over existing pixels does not remove them.

It is important to note that if you are expanding the length of the bus beyond what's in the save, you should also increase the `LIFE` of the 2 `LDTC`s (to the right of the "IO" text). If the `LIFE` is below the length of the bus, they may not be able to read from modules out of their reach, but if the `LIFE` is over the length of the bus, it may pick up `BRAY`s from something external besides IO modules.

The hardware may become complicated when an IO module needs to return more than a single value, or if it queues values. This is because when the computer needs to write to an address, such as `173@ram` or `9@io`, it first reads from it to check if the value inside it is another address that it needs to keep following, before writing to it.

If you are popping queued values when data is requested through the middle IO pin, it is best to not interrupt the queue by writing to the same module. Alternatively, you may have a single module use multiple IO ports (one for input and one for output), which is possible due to the massive maximum number of ports.