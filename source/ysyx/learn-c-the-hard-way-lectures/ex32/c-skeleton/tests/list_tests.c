#include "minunit.h"
#include <assert.h>
#include <lcthw/list.h>
#include <stdlib.h>
#include <time.h>

static List *list = NULL;
char *test_values[] = {"test1 data", "test2 data", "test3 data"};

char *test_create() {
  list = List_create();
  mu_assert(list != NULL, "Failed to create list.");
  mu_assert(List_count(list) == 0, "Initial count should be 0.");
  return NULL;
}

char *test_push_pop() {
  List_push(list, test_values[0]);
  mu_assert(List_last(list) == test_values[0], "Wrong last value after push.");

  List_push(list, test_values[1]);
  mu_assert(List_last(list) == test_values[1],
            "Wrong last value after second push.");

  List_push(list, test_values[2]);
  mu_assert(List_count(list) == 3, "Wrong count after pushes.");

  char *val = List_pop(list);
  mu_assert(val == test_values[2], "Wrong value on pop.");

  val = List_pop(list);
  mu_assert(val == test_values[1], "Wrong value on second pop.");

  mu_assert(List_count(list) == 1, "Wrong count after pops.");
  return NULL;
}

char *test_unshift_shift() {
  List_unshift(list, test_values[1]);
  mu_assert(List_first(list) == test_values[1],
            "Wrong first value after unshift.");

  char *val = List_shift(list);
  mu_assert(val == test_values[1], "Wrong value on shift.");

  mu_assert(List_count(list) == 1, "Should have 1 element left.");
  return NULL;
}

char *test_remove() {
  void *val = List_remove(list, list->first);
  mu_assert(val == test_values[0], "Wrong value on remove.");
  mu_assert(List_count(list) == 0, "List should be empty after remove.");

  return NULL;
}

char *test_destroy() {

  List_push(list, malloc(10));
  List_clear_destroy(list);
  return NULL;
}

List *create_list() {
  List *l = List_create();
  List_push(l, test_values[0]);
  List_push(l, test_values[1]);
  List_push(l, test_values[2]);
  return l;
}

char *test_join() {
  List *list_a = create_list();
  List *list_b = create_list();

  List_join(list_a, list_b);

  mu_assert(List_count(list_a) == 6, "List A count should be 6 after join.");
  mu_assert(List_count(list_b) == 0, "List B count should be 0 after join.");

  mu_assert(List_first(list_a) == test_values[0], "First of A wrong.");
  mu_assert(List_last(list_a) == test_values[2],
            "Last of A should be last of B.");

  ListNode *node3 = list_a->first->next->next;
  mu_assert(node3->next->value == test_values[0],
            "Join point connection failed.");

  List_destroy(list_a);
  List_destroy(list_b);

  return NULL;
}

char *test_split() {
  List *list_a = create_list();

  ListNode *node = list_a->first->next;

  List *list_b = List_split(list_a, node);

  mu_assert(List_count(list_a) == 1, "List A count wrong after split.");
  mu_assert(List_first(list_a) == test_values[0], "List A first wrong.");
  mu_assert(List_last(list_a) == test_values[0], "List A last wrong.");

  mu_assert(List_count(list_b) == 2, "List B count wrong after split.");
  mu_assert(List_first(list_b) == test_values[1], "List B first wrong.");
  mu_assert(List_last(list_b) == test_values[2], "List B last wrong.");

  List_destroy(list_a);
  List_destroy(list_b);

  return NULL;
}

int test_cmp(const void *a, const void *b) {
  return strcmp((const char *)a, (const char *)b);
}

int is_sorted(List *list, List_compare cmp) {
  if (List_count(list) <= 1)
    return 1;
  // 这里要注意：用 ListNode 指针
  ListNode *curr = list->first;
  while (curr->next) {
    if (cmp(curr->value, curr->next->value) > 0) {
      return 0; // 发现乱序
    }
    curr = curr->next;
  }
  return 1;
}

// 2. 冒泡排序测试
char *test_bubble_sort() {
  List *words = List_create();
  List_push(words, "test4");
  List_push(words, "test1");
  List_push(words, "test3");
  List_push(words, "test2");

  // Bubble sort 是原地排序
  int rc = List_bubble_sort(words, (List_compare)test_cmp);
  mu_assert(rc == 0, "Bubble sort failed.");
  mu_assert(is_sorted(words, (List_compare)test_cmp),
            "Words should be sorted after bubble sort.");

  List_destroy(words);
  return NULL;
}

// 3. 归并排序测试
char *test_merge_sort() {
  List *words = List_create();
  List_push(words, "test4");
  List_push(words, "test1");
  List_push(words, "test3");
  List_push(words, "test2");

  // 1. 执行排序，接收新链表
  List *res = List_merge_sort(words, (List_compare)test_cmp);

  // 2. 验证是否有序
  mu_assert(is_sorted(res, (List_compare)test_cmp),
            "Words should be sorted after merge sort.");

  // 3. --- [修复重点] ---
  // 这里必须用 ListNode*，否则报错 "no member named value"
  ListNode *curr = res->first;

  mu_assert(strcmp(curr->value, "test1") == 0, "First item should be test1");
  mu_assert(strcmp(curr->next->value, "test2") == 0,
            "Second item should be test2");

  // 4. 清理
  List_destroy(res);
  return NULL;
}

List *create_random_list(int count) {
  List *list = List_create();
  for (int i = 0; i < count; i++) {
    // 生成一个随机数字符串，例如 "823"
    char *str = calloc(32, sizeof(char));
    sprintf(str, "%d", rand());
    List_push(list, str);
  }
  return list;
}

// 性能对比测试
char *test_algorithm_performance() {
  int samples[] = {10, 100, 500, 1000, 2000, 5000}; // 测试不同的数据量
  int num_samples = 6;

  printf("\n--- Performance Benchmark ---\n");
  printf("| %-10s | %-15s | %-15s |\n", "Count", "Bubble Sort (s)",
         "Merge Sort (s)");
  printf("|------------|-----------------|-----------------|\n");

  for (int i = 0; i < num_samples; i++) {
    int count = samples[i];

    // 1. 准备数据：创建两个完全一样的随机链表
    // 我们不能用同一个链表测两次，因为第一次排完序后，第二次就是排有序链表了，不公平。
    List *list_for_bubble = create_random_list(count);
    List *list_for_merge = List_create();

    // 复制数据到第二个链表 (Deep Copy)
    ListNode *cur = list_for_bubble->first;
    while (cur) {
      List_push(list_for_merge, strdup((char *)cur->value)); // 复制字符串
      cur = cur->next;
    }

    // 2. 测试 Bubble Sort (O(n^2))
    clock_t start_b = clock();
    List_bubble_sort(list_for_bubble, (List_compare)test_cmp);
    clock_t end_b = clock();
    double time_bubble = (double)(end_b - start_b) / CLOCKS_PER_SEC;

    // 3. 测试 Merge Sort (O(n log n))
    clock_t start_m = clock();
    // Merge sort 返回新链表，旧的会被吞噬
    List *res_merge = List_merge_sort(list_for_merge, (List_compare)test_cmp);
    clock_t end_m = clock();
    double time_merge = (double)(end_m - start_m) / CLOCKS_PER_SEC;

    // 4. 打印结果
    printf("| %-10d | %-15.6f | %-15.6f |\n", count, time_bubble, time_merge);

    // 5. 清理内存
    // Bubble sort 的链表还在原地，需要手动销毁 (里面的字符串是 calloc 的，需要
    // List_clear_destroy 类似逻辑，或者这里简单处理) 注意：ex32 的 List_destroy
    // 默认只 free 节点，不 free value。
    // 为了避免内存泄漏太严重，这里简单演示，实际工程中需要遍历 free value。

    // 简单销毁容器（注意：这里会有 value 的内存泄漏，除非你实现了 List_clear）
    List_destroy(list_for_bubble);
    List_destroy(res_merge);
  }

  printf("--------------------------------------------------\n");
  printf("Note: As count increases, Bubble Sort time explodes!\n");

  return NULL;
}

char *test_insert_sorted() {
  List *words = List_create();

  // 故意乱序插入
  List_insert_sorted(words, "banana", (List_compare)test_cmp);
  List_insert_sorted(words, "apple", (List_compare)test_cmp); // 应该插在头
  List_insert_sorted(words, "orange", (List_compare)test_cmp); // 应该插在尾
  List_insert_sorted(words, "grape", (List_compare)test_cmp); // 应该插在中间

  // 验证是否有序
  mu_assert(is_sorted(words, (List_compare)test_cmp),
            "List_insert_sorted failed to keep list sorted!");

  // 验证特定位置
  mu_assert(strcmp(List_first(words), "apple") == 0, "First should be apple");
  mu_assert(strcmp(List_last(words), "orange") == 0, "Last should be orange");

  List_destroy(words);
  return NULL;
}

// 测试自底向上归并排序
char *test_bottom_up_merge_sort() {
  List *words = List_create();
  // 插入乱序数据
  List_push(words, "test4");
  List_push(words, "test1");
  List_push(words, "test3");
  List_push(words, "test2");
  List_push(words, "test5");

  // 调用新的排序函数
  List *res = List_bottom_up_merge_sort(words, (List_compare)test_cmp);

  // 验证
  mu_assert(is_sorted(res, (List_compare)test_cmp), "Bottom-up sort failed!");
  mu_assert(List_count(res) == 5, "Count mismatch after bottom-up sort");

  ListNode *curr = res->first;
  mu_assert(strcmp(curr->value, "test1") == 0, "First item wrong");
  mu_assert(strcmp(curr->next->value, "test2") == 0, "Second item wrong");

  List_destroy(res);
  return NULL;
}

char *all_tests() {
  mu_suite_start();

  mu_run_test(test_create);
  mu_run_test(test_push_pop);
  mu_run_test(test_unshift_shift);
  mu_run_test(test_remove);
  mu_run_test(test_destroy);

  mu_run_test(test_join);
  mu_run_test(test_split);

  mu_run_test(test_bubble_sort);
  mu_run_test(test_merge_sort);
  mu_run_test(test_algorithm_performance);
  mu_run_test(test_insert_sorted);
  mu_run_test(test_bottom_up_merge_sort);
  return NULL;
}

RUN_TESTS(all_tests);
