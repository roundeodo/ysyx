/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include "sdb.h"
#include "watchpoint.h"
#include "common.h"
#define NR_WP 32



static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool() {
  int i;
  for (i = 0; i < NR_WP; i ++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
  }

  head = NULL;
  free_ = wp_pool;
}

/* TODO: Implement the functionality of watchpoint */
WP* new_wp(){

  if(free_ == NULL){
    printf("Error: no free watchpoints \n");
    assert(0);
  }
  WP *temp;
  temp = free_;
  free_ = free_->next;
  temp->next = head;
  head = temp;
  return temp;
}

void free_wp(WP *wp){
  //delete from head list
  if(head == wp){
    head = head->next;
  }
  else{
    // find the previous node of wp
    WP *previous_node_of_wp = head;
    while(previous_node_of_wp != NULL && previous_node_of_wp->next != wp){
      previous_node_of_wp = previous_node_of_wp->next;
    }
    if(previous_node_of_wp == NULL){
      assert(0);
    }
    previous_node_of_wp->next = wp->next;
  }
  wp->old_value = 0;
  memset(wp->user_expression, 0, sizeof(wp->user_expression));
  wp->next = free_; //free_ is the head of free list
  free_ = wp;
}

void watchpoint_scan(){
  WP *current_node = head;
  bool success;
  word_t current_value;
  while(current_node != NULL){
    current_value = expr(current_node->user_expression, &success);
    if(success){
      if(current_value != current_node->old_value){
        printf("Hardware watchpoint %d: %s\n", current_node->NO, current_node->user_expression);
        printf("Old value = %llu (" FMT_WORD ")\n",
               (unsigned long long)current_node->old_value,
               current_node->old_value);
        printf("Current value = %llu (" FMT_WORD ")\n",
               (unsigned long long)current_value, current_value);
        printf("***************************************\n");
        current_node->old_value = current_value;
        nemu_state.state = NEMU_STOP;
      }
    }
    else{
      printf("Error: wrong expression\n");
    }
    current_node = current_node->next;
  }
}

void watchpoint_list(){
  if(head == NULL){
    printf("Error: no watchpoint available\n");
    return;
  }
  else{
    printf("Num     Type           Disp Enb Address            What\n");
    WP *ptr = head;
    while(ptr!= NULL){
      printf("%-8dhw watchpoint   keep y                      %s\n", ptr->NO, ptr->user_expression);
      printf("        curr value: %llu (" FMT_WORD ")\n",
             (unsigned long long)ptr->old_value, ptr->old_value);
      ptr = ptr->next;
    }
  }
}

bool delete_wp_by_number(int number){
  WP *ptr = head;
  while(ptr != NULL){
    if(ptr->NO == number){
      free_wp(ptr);
      return true;
    }
    ptr = ptr->next;
  }
  return false;
}
