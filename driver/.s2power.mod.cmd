savedcmd_s2power.mod := printf '%s\n'   s2power.o | awk '!x[$$0]++ { print("./"$$0) }' > s2power.mod
