#include <stdint.h>

#define FLASH_ENTRY_ADDR 0x30000000u
#define FLASH_RETURN_VALUE 0x58495031u

typedef uint32_t (*flash_entry_t)(void);

int main(void){
    flash_entry_t flash_entry = (flash_entry_t)(uintptr_t)FLASH_ENTRY_ADDR;

    uint32_t result = flash_entry();

    return result == FLASH_RETURN_VALUE ? 0 : 1;
}