extern int dvui_main(int argc, char *argv[]);

// SDL's Java glue dlsym()s SDL_main from this library; SDL_main.h would only rename main to it.
__attribute__((visibility("default"))) int SDL_main(int argc, char *argv[]) {
    return dvui_main(argc, argv);
}
