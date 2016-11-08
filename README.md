OpenNebula Fencing Script by LINFORGE
=====================================

enable (comment out) the host hook in /etc/one/oned.conf and add $TEMPLATE as the **second** argument:

HOST_HOOK = [
    NAME      = "error",
    ON        = "ERROR",
    COMMAND   = "ft/host_error_linforge.rb",
    ARGUMENTS = "$ID $TEMPLATE -m -p 5",
    REMOTE    = "no" ]

 
