#include "dbg.h"
#include <lcthw/list.h>

static inline void List_check_invariants(List *list) {
  assert(list->count >= 0 && "Invariant Failure: List count is negative.");
  if (list->count > 0) {
    assert(list->first != NULL &&
           "Invariant Failure: Non-empty list has NULL first.");
    assert(list->last != NULL &&
           "Invariant Failure: Non-empty list has NULL last.");
  } else {
    assert(list->first == NULL &&
           "Invariant Failure: Empty list has non-NULL first.");
    assert(list->last == NULL &&
           "Invariant Failure: Empty list has non-NULL last.");
  }
}

List *List_create() { return calloc(1, sizeof(List)); }

void List_destroy(List *list) {
  assert(list != NULL && "List_destroy: list cannot be NULL");

  LIST_FOREACH(list, first, next, cur) {
    if (cur->prev) {
      free(cur->prev);
    }
  }

  if (list->last) {
    free(list->last);
  }
  free(list);
}

void List_clear(List *list) {
  assert(list != NULL && "List_clear: list cannot be NULL");

  LIST_FOREACH(list, first, next, cur) {
    if (cur->value) {
      free(cur->value);
    }
  }
}

void List_clear_destroy(List *list) {
  assert(list != NULL && "List_clear_destroy: list cannot be NULL");

  ListNode *cur = list->first;
  ListNode *next = NULL;

  while (cur != NULL) {
    next = cur->next;
    if (cur->value)
      free(cur->value);
    free(cur);
    cur = next;
  }

  free(list);
}

void List_push(List *list, void *value) {
  assert(list != NULL && "List_push: list cannot be NULL");

  ListNode *node = calloc(1, sizeof(ListNode));
  check_mem(node);

  node->value = value;

  if (list->last == NULL) {
    list->first = node;
    list->last = node;
  } else {
    list->last->next = node;
    node->prev = list->last;
    list->last = node;
  }

  list->count++;

  // Invariant Check
  List_check_invariants(list);
  return;

error:
  return;
}

void *List_pop(List *list) {
  assert(list != NULL && "List_pop: list cannot be NULL");

  ListNode *node = list->last;
  return node != NULL ? List_remove(list, node) : NULL;
}

void List_unshift(List *list, void *value) {
  assert(list != NULL && "List_unshift: list cannot be NULL");

  ListNode *node = calloc(1, sizeof(ListNode));
  check_mem(node);

  node->value = value;

  if (list->first == NULL) {
    list->first = node;
    list->last = node;
  } else {
    node->next = list->first;
    list->first->prev = node;
    list->first = node;
  }

  list->count++;

  // Invariant Check
  List_check_invariants(list);
  return;

error:
  return;
}

void *List_shift(List *list) {
  assert(list != NULL && "List_shift: list cannot be NULL");

  ListNode *node = list->first;
  return node != NULL ? List_remove(list, node) : NULL;
}

void *List_remove(List *list, ListNode *node) {
  assert(list != NULL && "List_remove: list cannot be NULL");
  assert(node != NULL && "List_remove: node cannot be NULL");

  void *result = NULL;

  if (node == list->first && node == list->last) {
    list->first = NULL;
    list->last = NULL;
  } else if (node == list->first) {
    list->first = node->next;
    check(list->first != NULL,
          "Invalid list, somehow got a first that is NULL.");
    list->first->prev = NULL;
  } else if (node == list->last) {
    list->last = node->prev;
    check(list->last != NULL, "Invalid list, somehow got a next that is NULL.");
    list->last->next = NULL;
  } else {
    ListNode *after = node->next;
    ListNode *before = node->prev;
    after->prev = before;
    before->next = after;
  }

  list->count--;
  result = node->value;
  free(node);

  // Invariant Check
  List_check_invariants(list);

  return result;

error:
  return NULL;
}

void List_join(List *list1, List *list2) {
  assert(list1 != NULL && "List_join: list1 cannot be NULL");
  assert(list2 != NULL && "List_join: list2 cannot be NULL");

  if (list2->count == 0)
    return;

  if (list1->count == 0) {
    list1->first = list2->first;
    list1->last = list2->last;
    list1->count = list2->count;
  } else {
    list1->last->next = list2->first;
    list2->first->prev = list1->last;
    list1->last = list2->last;
    list1->count += list2->count;
  }

  list2->count = 0;
  list2->first = NULL;
  list2->last = NULL;
}

List *List_split(List *list, ListNode *node) {
  assert(list != NULL && "List_split: list cannot be NULL");
  assert(node != NULL && "List_split: node cannot be NULL");

  List *result = List_create();
  assert(result != NULL && "Failed to create result list");

  if (node == list->first) {
    result->first = list->first;
    result->last = list->last;
    result->count = list->count;

    list->first = NULL;
    list->last = NULL;
    list->count = 0;
    return result;
  }

  ListNode *before = node->prev;

  int result_count = 0;
  ListNode *scan = node;
  while (scan != NULL) {
    result_count++;
    scan = scan->next;
  }

  result->first = node;
  result->last = list->last;
  result->count = result_count;
  result->first->prev = NULL;

  list->last = before;
  list->last->next = NULL;
  list->count -= result_count;

  return result;
}

int List_bubble_sort(List *list, List_compare cmp) {
  int sorted = 1;

  if (List_count(list) <= 1) {
    return 0;
  }

  do {
    sorted = 1;
    ListNode *cur = list->first;

    while (cur->next) {
      if (cmp(cur->value, cur->next->value) > 0) {
        void *temp = cur->value;
        cur->value = cur->next->value;
        cur->next->value = temp;

        sorted = 0;
      }
      cur = cur->next;
    }
  } while (!sorted);

  return 0;
}

List *List_merge(List *left, List *right, List_compare cmp) {
  List *result = List_create();
  void *val = NULL;

  while (List_count(left) > 0 && List_count(right) > 0) {
    if (cmp(List_first(left), List_first(right)) <= 0) {
      val = List_shift(left);
    } else {
      val = List_shift(right);
    }
    List_push(result, val);
  }

  if (List_count(left) > 0) {
    List_join(result, left);
  }

  if (List_count(right) > 0) {
    List_join(result, right);
  }

  if (left)
    free(left);
  if (right)
    free(right);

  return result;
}

List *List_merge_sort(List *list, List_compare cmp) {
  // Base Case
  if (List_count(list) <= 1) {
    return list;
  }

  // --- [修复重点] ---
  // 之前的逻辑在 count=2 时会导致 node 停在第一个节点，造成死循环。
  // 我们必须让 node 走到后半段的开头。
  // 改成 i < half，确保只有两个节点时，node 也能指向第二个节点。
  int half = List_count(list) / 2;
  ListNode *node = list->first;
  for (int i = 0; i < half; i++) {
    if (node->next)
      node = node->next;
  }

  // Split: 从 node 开始切分，list 是前半段，second 是后半段
  List *second = List_split(list, node);

  // Recurse: 递归排序
  List *sort_left = List_merge_sort(list, cmp);
  List *sort_right = List_merge_sort(second, cmp);

  // Merge: 合并
  return List_merge(sort_left, sort_right, cmp);
}

void List_insert_sorted(List *list, void *value, List_compare cmp) {
  // 1. 创建新节点
  ListNode *node = calloc(1, sizeof(ListNode));
  check_mem(node); // 假设你有 check_mem，如果没有就用 if(!node) exit(1);
  node->value = value;

  // Case 0: 链表为空，直接放入
  if (list->first == NULL) {
    list->first = node;
    list->last = node;
    list->count++;
    return;
  }

  // Case 1: 新值比头节点还小 (或相等)，插在头部
  if (cmp(value, list->first->value) <= 0) {
    node->next = list->first;
    list->first->prev = node;
    list->first = node;
    list->count++;
    return;
  }

  // Case 2: 遍历寻找插入点 (插在 curr 之后)
  ListNode *curr = list->first;
  // 只要 curr 后面还有节点，且新值比后面的节点大，就继续往后找
  while (curr->next != NULL && cmp(value, curr->next->value) > 0) {
    curr = curr->next;
  }

  // 执行插入操作：插在 curr 和 curr->next 之间
  node->next = curr->next;
  node->prev = curr;

  if (curr->next) {
    curr->next->prev = node;
  } else {
    // 如果 curr->next 是 NULL，说明插到了末尾，更新 last
    list->last = node;
  }

  curr->next = node;
  list->count++;

error: // 为了配合 check_mem 的标签，如果没有用 dbg.h 可以忽略
  return;
}

// 练习3: List_bottom_up_merge_sort 实现
// 这是一个非常经典的迭代归并实现，使用一个数组 pending[]
// 来暂存不同“高度”的归并树 类似于二进制计数器的原理：pending[0]
// 存长度1的链表，pending[1] 存长度2的...
List *List_bottom_up_merge_sort(List *list, List_compare cmp) {
  if (List_count(list) <= 1)
    return list;

  List *pending[32]; // 足够处理 2^32 个节点的链表
  for (int i = 0; i < 32; i++)
    pending[i] = NULL;

  List *result = NULL;
  ListNode *curr = list->first;
  ListNode *next_node = NULL;

  // 1. 拆解原链表，逐个处理节点
  while (curr != NULL) {
    next_node = curr->next; // 保存下一个位置

    // 把当前节点变成一个独立的链表 'carry'
    List *carry = List_create();
    List_push(carry, curr->value);

    // 2. 尝试往 pending 数组里合并 (进位逻辑)
    int i = 0;
    while (i < 32 && pending[i] != NULL) {
      // 如果这一层已经有链表了，就合并它们，并继续往上一层进位
      List *merged = List_merge(pending[i], carry, cmp);
      // List_merge 会销毁输入的两个链表结构，返回新的
      // 所以 pending[i] 和 carry 此时已经是无效指针了，需要更新
      pending[i] = NULL;
      carry = merged;
      i++;
    }

    // 找到了空位，把 carry 放进去
    if (i < 32) {
      pending[i] = carry;
    } else {
      // 防御性：如果超过32层（不太可能），销毁 carry 防止泄露
      List_destroy(carry);
    }

    curr = next_node;
  }

  // 3. 收尾：把 pending 数组里剩下的所有片段合并起来
  result = List_create(); // 创建一个空的结果
  for (int i = 0; i < 32; i++) {
    if (pending[i] != NULL) {
      // 将片段合并到最终结果里
      // 注意：List_merge(A, B) 返回合并后的，且消耗掉 A 和 B
      // 这里为了处理第一次 result 为空的情况，List_merge 内部最好能处理空链表
      // 如果你的 List_merge 不支持其中一个是空链表，这里需要加个判断
      if (List_count(result) == 0) {
        List_destroy(result); // 丢弃这个空壳
        result = pending[i];
      } else {
        result = List_merge(result, pending[i], cmp);
      }
    }
  }

  // 原来的 list 已经被掏空了，需要销毁它这个壳子
  // 注意：这里的 list 结构体本身还在，只是节点都被拿走了，需要重置或者销毁
  // 按照通常习惯，List_bottom_up_merge_sort 应该像 List_merge_sort
  // 一样接管原链表 我们可以简单地重置原 list 并 destroy，或者直接 destroy。
  // 为了安全，这里不手动 free(list)，因为可能在外面是 stack 变量
  // 但根据 ex33 的风格，最好是把 list 清空，或者直接让用户负责销毁旧的。
  // 这里我们手动把原 list 的指针清空，防止 double free
  list->first = NULL;
  list->last = NULL;
  list->count = 0;
  List_destroy(list);

  return result;
}
