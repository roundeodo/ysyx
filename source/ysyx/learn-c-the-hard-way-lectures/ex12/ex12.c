#include <stdio.h>

int main(int argc, char *argv[])
{
    int areas[] = { 10, 12, 13, 14, 20 };
    char name[] = "Zed";
    char full_name[] = {
        'Z', 'e', 'd',
        ' ', 'A', '.', ' ',
        'S', 'h', 'a', 'w' 
    };

    // WARNING: On some systems you may have to change the
    // %ld in this code to a %u since it will use unsigned ints
    printf("The size of an int: %ld\n", sizeof(int));
    printf("The size of areas (int[]): %ld\n", sizeof(areas));
    printf("The number of ints in areas: %ld\n",
            sizeof(areas) / sizeof(int));
    printf("The first area is %d, the 2nd %d.\n", areas[0], areas[1]);

    printf("The size of a char: %ld\n", sizeof(char));
    printf("The size of name (char[]): %ld\n", sizeof(name));
    printf("The number of chars: %ld\n", sizeof(name) / sizeof(char));

    printf("The size of full_name (char[]): %ld\n", sizeof(full_name));
    printf("The number of chars: %ld\n",
            sizeof(full_name) / sizeof(char));


    full_name[10] = '\0';
		printf("name=\"%s\" and full_name=\"%s\"\n", name, full_name);
		printf("full name 10 = %c\n",full_name[10]);

		areas[0] = 100;
		printf("area 0 = %d\n",areas[0]);
		full_name[9] = 'F';
		printf("full_name[9] = %c\n",full_name[9]);
		name[1] = 'F';
		printf("name[1] = %c\n",name[1]);
		areas[1] = (int)name[1];
		printf("area[1] = %c\n",areas[1]);
        return 0;
}
