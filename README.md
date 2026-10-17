# Unraid UGREEN LED Driver Plugin (maintained fork)

Drives the disk, network and power LEDs on UGREEN NAS units running Unraid.
This is a community-maintained continuation of [ich777/unraid-ugreenleds-driver](https://github.com/ich777/unraid-ugreenleds-driver)
(deprecated, capped at Unraid 7.3.2), built on [miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller).
All credit for the original driver and daemon goes to ich777 and miskcoo.

**Install URL** (Plugins → Install Plugin):

```
https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/unraid-ugreenleds-driver/master/ugreenleds-driver.plg
```

## Why the original stopped working on 7.3.3

1. The `.plg` declared `max="7.3.2"`, so Unraid refuses to install it on 7.3.3.
2. The kernel module was downloaded from ich777's GitHub releases, one build per kernel. Those stop at `6.18.45-Unraid`; Unraid 7.3.3 runs `6.18.54-Unraid`, so there is nothing to download.
3. Some of the later prebuilt modules were compiled with a different kernel config than Unraid ships (`CONFIG_LEDS_BRIGHTNESS_HW_CHANGED`). The module loads, but `struct led_classdev` is 16 bytes larger in the real kernel, which corrupts the driver's data and hard-locks the NAS ([miskcoo#129](https://github.com/miskcoo/ugreen_leds_controller/issues/129)). That is the "server hangs / loses network" report people saw.

## What this fork changes

- No upper version cap.
- The kernel module lives in this repo under `packages/kmod/<kernel>/` and is built by `source/build-kmod.sh` from the **official Unraid image's own kernel config and patches**. The build refuses to package if the vermagic, the `struct led_classdev` size, or any symbol doesn't match the shipped kernel.
- A GitHub Action rebuilds automatically every week when a new stable Unraid version appears, and can be run by hand for betas/RCs.
- Short download timeouts, so a boot without network can't stall the plugin.
- If no module exists for your kernel yet, the plugin stays installed and tells you, instead of failing.
- Kill switch: `touch /boot/config/plugins/ugreenleds-driver/disabled` keeps the driver from loading at boot.
- Daemon fixes: second instance no longer deletes the running instance's lock, no duplicate I²C client on restart, network color resets correctly, link speed is read through `br0`/`bond0` to the physical port, 5 GbE color added, optional `NETDEV_INTERFACE` override.
- Driver fix: the `status` sysfs attribute used an unchecked array index.
- No longer downloads ich777's `plugin_update_helper` at install time.

## Supported models

DX4600, DX4700, DXP2800, DXP4800 (incl. Plus/Pro), DXP6800, DXP8800, DXP480T (static white LED only).

## Settings

`/boot/config/plugins/ugreenleds-driver/settings.cfg` — restart with `pkill -f /usr/bin/ugreen-leds; echo /usr/bin/ugreen-leds | at now`.

| Key | Default | Meaning |
|---|---|---|
| `MAPPING_METHOD` | `ata` | `ata`, `hctl` or `serial` |
| `DISK_SERIAL` | `SN1 SN2 SN3 SN4` | Serials in bay order (only for `serial`) |
| `COLOR_DISK_HEALTH` | `255 255 255` | Healthy disk |
| `COLOR_DISK_UNAVAIL` | `255 0 0` | Disk went offline |
| `BRIGHTNESS_DISK_LEDS` | `255` | 0–255 |
| `LED_REFRESH_INTERVAL` | `0.5` | Disk activity poll (s) |
| `CHECK_DISK_ONLINE_INTERVAL` | `5` | Disk presence poll (s) |
| `CHECK_GATEWAY_CONNECTIVITY` | `true` | Ping the gateway, red if unreachable |
| `COLOR_NETDEV_NORMAL` | `255 165 0` | Unknown link speed |
| `COLOR_NETDEV_LINK_100/1000/2500/5000/10000` | green / blue / yellow / cyan / white | Per link speed |
| `COLOR_NETDEV_GATEWAY_UNREACHABLE` | `255 0 0` | |
| `CHECK_NETDEV_INTERVAL` | `30` | Gateway check (s) |
| `NETDEV_INTERFACE` | *(auto)* | Force the interface the network LED follows |

## Building a module for a new Unraid release

GitHub: **Actions → Build kernel module → Run workflow**, enter the version (and the zip URL for betas/RCs).

Locally (Ubuntu/Debian, as root):

```bash
apt-get install build-essential bc flex bison libelf-dev libssl-dev cpio squashfs-tools zstd xz-utils unzip curl jq python3 kmod
./source/build-kmod.sh 7.3.3
git add packages/kmod && git commit -m "kmod: Unraid 7.3.3" && git push
```

After changing the daemon (`source/usr/bin/ugreen-leds`), run `./source/makepkg-unraid.sh <version> <path-to-makepkg>` and update `version`/`md5` in the `.plg`.

## Troubleshooting

- `grep ugreen-leds /var/log/syslog` shows model detection, disk mapping and errors.
- `lsmod | grep led_ugreen` and `ls /sys/class/leds` confirm the driver attached.
- If the server ever hangs after enabling this, reboot, create the `disabled` file above, and open an issue with your Unraid version.

## Credits

[miskcoo](https://github.com/miskcoo/ugreen_leds_controller) (driver), [ich777](https://github.com/ich777/unraid-ugreenleds-driver) (original plugin), [guyp2k](https://github.com/guyp2k/UGREEN-LEDs-unRAID) (lock-up root-cause analysis).
