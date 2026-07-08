#!/system/bin/sh
# Sanity notes at install time, nothing more — payload is a plain
# /vendor/lib/modules overlay handled by Magisk's magic mount.

case "$(uname -r)" in
*g96adfa8256dc*)
    ui_print "- Running on the Determination kernel — modules will overlay on reboot" ;;
*)
    ui_print "! Not running the Determination kernel right now."
    ui_print "! Installing anyway; the overlay stays dormant until that kernel boots."
    ;;
esac
ui_print "- Modules included:"
for f in "$MODPATH"/system/vendor/lib/modules/*.ko; do
    ui_print "    ${f##*/}"
done
