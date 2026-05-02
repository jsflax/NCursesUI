#ifndef CNCURSES_H
#define CNCURSES_H

#include <curses.h>
#include <panel.h>
#include <locale.h>

// ncurses macros that don't bridge to Swift as they expand to complex expressions

// Attribute constants
static inline int tui_a_bold(void)      { return (int)A_BOLD; }
static inline int tui_a_dim(void)       { return (int)A_DIM; }
static inline int tui_a_reverse(void)   { return (int)A_REVERSE; }
static inline int tui_a_underline(void) { return (int)A_UNDERLINE; }
static inline int tui_a_normal(void)    { return (int)A_NORMAL; }

// A_ITALIC was added in ncurses 5.9 (2011). macOS system ncurses 5.7 and
// some embedded builds predate it; fall back to a hardcoded NCURSES_BITS
// (1U,23) — the same bit position 6.x uses. If terminfo's `sitm` is
// missing the bit silently no-ops at draw time (ncurses skips emitting
// SGR 3), so this is safe; callers should consult tui_has_italic().
#ifdef A_ITALIC
static inline int tui_a_italic(void)    { return (int)A_ITALIC; }
#else
static inline int tui_a_italic(void)    { return (int)((1U) << (23 + 8)); }
#endif

// Probe terminfo for italic-on (`sitm`) capability. Use at startup to
// decide whether italic should fall back to underline. Cached by callers.
// Note: `tigetstr` returns (char *)-1 for invalid names and NULL for
// terminfo entries that don't define the cap — we treat both as "no".
#include <term.h>
static inline int tui_has_italic_cap(void) {
    char name[5] = {'s', 'i', 't', 'm', 0};
    char *s = tigetstr(name);
    return (s != NULL && s != (char *)-1) ? 1 : 0;
}

// COLOR_PAIR macro
static inline int tui_color_pair(int n) { return (int)COLOR_PAIR(n); }

// Custom color definition (for palette RGB registration). Scale is 0..1000.
// `can_change_color` reports whether init_color is usable. Most modern
// terminals (Terminal.app, iTerm2, kitty) support it with TERM=xterm-256color.
static inline int tui_can_change_color(void) { return can_change_color() ? 1 : 0; }
static inline int tui_init_color(int idx, int r, int g, int b) {
    return init_color((short)idx, (short)r, (short)g, (short)b);
}
static inline int tui_init_pair(int pair, int fg, int bg) {
    return init_pair((short)pair, (short)fg, (short)bg);
}
static inline int tui_colors(void) { return COLORS; }
static inline int tui_color_pairs(void) { return COLOR_PAIRS; }

// Screen dimensions (LINES/COLS are macros or extern globals)
static inline int tui_lines(void) { return LINES; }
static inline int tui_cols(void)  { return COLS; }

// Window dimensions
static inline int tui_getmaxy(WINDOW *w) { return getmaxy(w); }
static inline int tui_getmaxx(WINDOW *w) { return getmaxx(w); }

// Attribute on/off (may be macros in some ncurses versions)
static inline void tui_wattron(WINDOW *w, int a)  { wattron(w, a); }
static inline void tui_wattroff(WINDOW *w, int a) { wattroff(w, a); }

// stdscr accessor — avoids Swift 6 concurrency warnings on the C global
static inline WINDOW *tui_stdscr(void) { return stdscr; }

// Audible / visual bell. Routes through ncurses (terminfo `bel` cap, with
// `flash()` fallback when bel is missing) so it interleaves with the
// curses output buffer instead of getting eaten by it. Wrapped because
// `beep` is sometimes a macro and the bare Swift import may not pick it
// up cleanly across ncurses versions.
static inline int tui_beep(void) { return beep(); }

// Pads — off-screen buffers that can be viewport-blitted to the screen.
// The ScrollView primitive allocates one pad per scrollable region, draws
// its full content into the pad, and uses pnoutrefresh to show only a
// sliding viewport.
static inline WINDOW *tui_newpad(int rows, int cols) { return newpad(rows, cols); }
static inline int tui_delwin(WINDOW *w) { return delwin(w); }
static inline int tui_werase(WINDOW *w) { return werase(w); }
static inline int tui_pnoutrefresh(WINDOW *pad, int py, int px,
                                   int sy1, int sx1, int sy2, int sx2) {
    return pnoutrefresh(pad, py, px, sy1, sx1, sy2, sx2);
}
static inline int tui_wnoutrefresh(WINDOW *w) { return wnoutrefresh(w); }
static inline int tui_doupdate(void) { return doupdate(); }

// Mouse — wheel support for ScrollView. xterm SGR mouse protocol (?1006h)
// gives us coordinates past column 223 and makes event decoding stable.
// We request ALL_MOUSE_EVENTS because the specific wheel masks differ
// between ncurses builds (BUTTON4/5_PRESSED on most, WHEEL_UP/DOWN on
// some); we filter in Swift.
static inline int tui_getmouse(MEVENT *e) { return getmouse(e); }
static inline mmask_t tui_all_mouse_events(void) { return ALL_MOUSE_EVENTS; }
static inline unsigned long tui_button1_pressed(void) { return BUTTON1_PRESSED; }
static inline unsigned long tui_button4_pressed(void) { return BUTTON4_PRESSED; }
static inline unsigned long tui_button5_pressed(void) {
#ifdef BUTTON5_PRESSED
    return BUTTON5_PRESSED;
#else
    // ncurses 5.7 (and earlier) don't define BUTTON5_PRESSED. Hardcode the
    // ncurses 6.x bit position (pressed = `002L << 24` = 0x2000000) so we
    // still recognize wheel-down events that the terminal generates even
    // when the SDK headers predate button 5.
    return 0x2000000UL;
#endif
}
static inline int tui_key_mouse(void) { return KEY_MOUSE; }
static inline void tui_enable_mouse(void) {
    // ncurses 6.x on macOS decodes SGR mouse reports into KEY_MOUSE with
    // proper bstate flags — wheel-up arrives as BUTTON4_PRESSED (0x80000)
    // and wheel-down as BUTTON5_PRESSED (0x2000000). We just need to
    // request all mouse events. The `\033[?1006h` write below is belt-and-
    // suspenders to ensure SGR mode is on even if some terminals default
    // to the legacy X10 protocol (which loses coords past col 223).
    mousemask(ALL_MOUSE_EVENTS, NULL);
    fputs("\033[?1000h\033[?1006h", stdout);
    fflush(stdout);
}
static inline void tui_disable_mouse(void) {
    fputs("\033[?1006l\033[?1000l", stdout);
    fflush(stdout);
    mousemask(0, NULL);
}

// Windows — needed for per-overlay draw targets backed by libpanel.
// Unlike pads (newpad), these have screen positions and participate in
// the panel stack. `tui_newwin` creates a positioned window, `tui_mvwin`
// repositions it, and `tui_wclear`/`tui_wnoutrefresh` manage its content.
static inline WINDOW *tui_newwin(int rows, int cols, int y, int x) {
    return newwin(rows, cols, y, x);
}
static inline int tui_mvwin(WINDOW *w, int y, int x) { return mvwin(w, y, x); }
static inline int tui_wresize(WINDOW *w, int rows, int cols) {
    return wresize(w, rows, cols);
}
static inline int tui_wclear(WINDOW *w) { return wclear(w); }

// Change the attributes of N cells starting at (y, x) WITHOUT overwriting
// the characters. Used by Overlay's dim-background pass: walk the main
// panel's visible cells outside the overlay rect and OR in A_DIM.
static inline int tui_mvwchgat(WINDOW *w, int y, int x, int n, int attr, short pair) {
    return mvwchgat(w, y, x, n, (attr_t)attr, pair, NULL);
}

// libpanel — stackable windows. `update_panels` recomputes which cells of
// each window are visible based on z-order; `doupdate` then flushes. The
// top panel's keystrokes are routed by our own dispatch; libpanel just
// manages the visible-region arithmetic.
static inline PANEL *tui_new_panel(WINDOW *w)        { return new_panel(w); }
static inline int    tui_del_panel(PANEL *p)         { return del_panel(p); }
static inline int    tui_top_panel(PANEL *p)         { return top_panel(p); }
static inline int    tui_bottom_panel(PANEL *p)      { return bottom_panel(p); }
static inline int    tui_hide_panel(PANEL *p)        { return hide_panel(p); }
static inline int    tui_show_panel(PANEL *p)        { return show_panel(p); }
static inline int    tui_panel_hidden(const PANEL *p){ return panel_hidden(p); }
static inline int    tui_move_panel(PANEL *p, int y, int x) { return move_panel(p, y, x); }
static inline int    tui_replace_panel(PANEL *p, WINDOW *w) { return replace_panel(p, w); }
static inline void   tui_update_panels(void)         { update_panels(); }
static inline WINDOW *tui_panel_window(const PANEL *p) { return panel_window(p); }

#endif
