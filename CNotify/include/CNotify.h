//
//  CNotify.h
//  Exposes the C <notify.h> API (notify_register_dispatch / notify_cancel /
//  NOTIFY_STATUS_OK) to Swift. These live in libSystem but are not part of the
//  default Darwin Swift overlay, so we surface them through this shim module.
//
#ifndef CNOTIFY_H
#define CNOTIFY_H

#include <notify.h>

#endif /* CNOTIFY_H */
