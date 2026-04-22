#ifndef CNCURSES_H
#define CNCURSES_H

#include <curses.h>
#include <locale.h>

// ncurses macros that don't bridge to Swift as they expand to complex expressions

// Attribute constants
static inline int tui_a_bold(void)      { return (int)A_BOLD; }
static inline int tui_a_dim(void)       { return (int)A_DIM; }
static inline int tui_a_reverse(void)   { return (int)A_REVERSE; }
static inline int tui_a_underline(void) { return (int)A_UNDERLINE; }
static inline int tui_a_normal(void)    { return (int)A_NORMAL; }

// COLOR_PAIR macro
static inline int tui_color_pair(int n) { return (int)COLOR_PAIR(n); }

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

#endif
