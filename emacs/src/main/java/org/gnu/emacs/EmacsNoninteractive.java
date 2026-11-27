/* Communication module for Android terminals.  -*- c-file-style: "GNU" -*-

Copyright (C) 2023-2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

package org.gnu.emacs;

/* Upstream entry-point STUB (emacshell rehoming, Owner order
   2026-11-27).  libandroid-emacs.so -- the GNU native helper that
   emacshell never rebuilds (DESIGN.org "No Emacs C rebuild, ever")
   -- hardcodes THIS class name on the app_process command line it
   uses to start noninteractive Emacs, so the name cannot change.
   The real implementation lives in the emacshell namespace:
   tech.khalidrafi.emacshell.EmacshellNoninteractive.  This stub's
   only job is to forward `main' to it; both classes live in the
   same classes.dex, so the system class loader that loads this stub
   resolves the emacshell class through the same class path.  */

public final class EmacsNoninteractive
{
  public static void
  main (String[] args)
  {
    tech.khalidrafi.emacshell.EmacshellNoninteractive.main (args);
  }
}
