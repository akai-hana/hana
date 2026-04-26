### NOTES:

- All parameters and values are cApS-iNsEnSiTiVe. 
- Strings can be set with single or double quotes (''/"").
- Decimal values can use a dot (N.NN) or comma (N,NN).
- Any percentage value can be decimal (N.NN%/%N.NN).

+ Parameters can be set to a numerical value N (px) or N%/%N (ratio)
  - 'N' represents an exact amount of pixels occupied on the screen.
  + 'N%' represents either a ratio or the scaling of a default value.
     - For example, `gap_width = 5%` will make the gaps of windows
       take up 5% of the total display's viewable area.
     - As for default value scaling, 'indicator_size = 125%' will make
        the workspace indicators be +25% of their default 100% (5 px).

+ Keys in a keybind can be expanded by using `{}` in the key combination
  in order to set an array of keybinds, effectively assigning a single
  action to multiple key combinations in the same line.
  - `Mod+{Q,W,E,R} = "workspace"` sets workspace switching to 4 binds,
    Mod+Q through R.
  - `Mod+{1-9} = "workspace"` sets workspace switching to 9 binds, keys
    Mod+1 through 9.
  - Both can be combined at will: `Mod+{1-4,Q,W,E,R} = "workspace"`.

+ `{}` in place of the action instead of the keybind serves as an alias
  ```toml
  Mod+L = "larry"
  kill = "pkill -9"
  Mod+Shift+L = "{kill} larry"
  ```
  
+ A single keybind can invoke multiple actions at once.
  - `Mod+A = "foo"; Mod+A = "bar"` aren't conflicting;
    both `foo` and `bar` will be executed upon pressing Mod+A.
  - More conveniently, arrays of actions can be set onto a bind:
    `Mod+A = ["foo", "bar"]`
