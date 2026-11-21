# chiaki-ng's library asks for libevent unless it is built as part of chiaki-ng's own Android app
# (CHIAKI_ENABLE_ANDROID). The phone apps don't use it (it serves Remote Play over the internet):
# an empty libevent stands in, as in the Android app.
set(libevent_FOUND TRUE)
set(LIBEVENT_INCLUDE_DIRS "")
set(LIBEVENT_LIBRARIES "")
