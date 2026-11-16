#pragma once

#include <stdint.h>

void init_wp_pool();

void new_wp(const char *expr_str);

void free_wp(int no);

void display_watchpoints();

bool check_watchpoints();