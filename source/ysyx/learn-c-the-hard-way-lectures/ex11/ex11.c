#include <stdio.h>

int main(int argc, char *argv[]) {
    int numbers[4] = {0};
    char name[4] = {'a', 'a', 'a', 'a'};
    int *magic_int_ptr = (int *)name;
    // first, print them out raw
    printf("numbers: %d %d %d %d\n", numbers[0], numbers[1], numbers[2],
           numbers[3]);

    printf("name each: %c %c %c %c\n", name[0], name[1], name[2], name[3]);

    printf("name: %s\n", name);

    printf("print the name like a big number: %d\n", *magic_int_ptr);

    printf("the first 'int' in name array: %d\n", magic_int_ptr[1]);

    // setup the numbers

    numbers[0] = name[0];
    numbers[1] = name[1];
    numbers[2] = name[2];
    numbers[3] = name[3];

    // setup the name
    name[0] = 64;
    name[1] = 'e';
    name[2] = 'd';
    name[3] = 'A';

    // then print them out initialized
    printf("numbers: %d %d %d %d\n", numbers[0], numbers[1], numbers[2],
           numbers[3]);

    printf("name each: %c %c %c %c\n", name[0], name[1], name[2], name[3]);

    // print the name like a string
    printf("name: %s\n", name);

    // another way to use name
    char *another = "Zed";

    printf("another: %s\n", another);

    printf("another each: %c %c %c %c\n", another[0], another[1], another[2],
           another[3]);

    int a = 0xaabbccdd;
    // char a_character [4];
    char *a_character = "aaaa";
    *((int *)a_character) = a;
    printf("charater = %x\n", *((int *)a_character));

    return 0;
}
