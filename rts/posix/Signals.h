/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team, 1998-2005
 *
 * Signal processing / handling.
 *
 * ---------------------------------------------------------------------------*/

#ifndef POSIX_SIGNALS_H
#define POSIX_SIGNALS_H

#ifdef HAVE_SIGNAL_H
# include <signal.h>
#endif

BEGIN_RTS_PRIVATE

rtsBool anyUserHandlers(void);

#if !defined(THREADED_RTS)
extern siginfo_t pending_handler_buf[];
extern siginfo_t *next_pending_handler;
#define signals_pending() (next_pending_handler != pending_handler_buf)
void startSignalHandlers(Capability *cap);
#endif

Capability *ioManagerStartCap (Capability *cap);

extern StgInt *signal_handlers;

END_RTS_PRIVATE

#endif /* POSIX_SIGNALS_H */

