# Composer test checklist

Run on the Windows VM in Composer Pro after copying the files from `build/`.
Note the driver version shown in each driver's "Driver Version" property.

## Scaffold build

1. Drivers → Add or update drivers → add `hue_bridge.c4z` and `hue_light.c4z`.
   Expect no import errors.
2. Add **Hue Bridge** to a room.
   - Properties: `Status` reads "Enter the bridge IP address"; `Driver Version`
     matches the build.
3. Set `Bridge IP Address` to the bridge's IP and press Set.
   - `Status` changes to "Not paired".
4. Set `Bridge IP Address` to `abc` and press Set.
   - `Status` goes back to "Enter the bridge IP address".
   - With `Debug Mode` = On, the Lua output shows a warning about the IP.
5. Add **Hue Light** to a room.
   - `Status` reads "Not connected to a Hue Bridge".
   - Connections tab: the light has a "Hue Bridge" connection that binds to the
     bridge's "Hue Lights" connection. Bind it.
   - In a Navigator, the light shows as offline/at 0% and doesn't throw errors
     when tapped.
6. Restart Director (or reboot the controller). Both drivers come back with
   the same status, and the Lua output shows no errors.

Report anything that differs, including exact Lua output lines.
