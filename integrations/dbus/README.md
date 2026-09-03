# FileSail FileManager1 D-Bus integration

This package is optional. Install the regular `filesail` package first, then
build and install this package from this directory:

```sh
makepkg -si
```

`filesail-dbus` installs the native `org.freedesktop.FileManager1` service and
a user-level systemd unit. It does not install a system D-Bus activation file,
so it can coexist with packages such as Nautilus that already own
`/usr/share/dbus-1/services/org.freedesktop.FileManager1.service`.

Enable FileSail as the session file manager:

```sh
systemctl --user daemon-reload
systemctl --user enable --now filesail-filemanager1.service
```

Check that FileSail owns the well-known name:

```sh
busctl --user status org.freedesktop.FileManager1
gdbus introspect --session \
  --dest org.freedesktop.FileManager1 \
  --object-path /org/freedesktop/FileManager1
```

If the service fails to start, inspect its log:

```sh
systemctl --user status filesail-filemanager1.service
journalctl --user -u filesail-filemanager1.service -b
```

Only one application can own `org.freedesktop.FileManager1` at a time. If
`busctl` reports Nautilus, Thunar, or another file manager, close or stop that
application before starting FileSail. The existing package does not need to be
removed.

To stop using the integration:

```sh
systemctl --user disable --now filesail-filemanager1.service
```

`ShowFolders` and `ShowItems` handle local `file://` URIs and absolute paths.
Remote URIs are ignored safely. `ShowItemProperties` is currently exposed for
interface compatibility but does not yet provide a properties dialog.
