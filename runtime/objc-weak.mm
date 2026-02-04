/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

// 包含Objective-C私有头文件
#include "objc-private.h"

// 包含弱引用头文件
#include "objc-weak.h"

// 包含标准整数类型头文件
#include <stdint.h>
// 包含标准布尔类型头文件
#include <stdbool.h>
// 包含系统类型定义头文件
#include <sys/types.h>

// 定义宏：计算表的大小（根据掩码计算）
#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)

// 前向声明：添加弱引用者到条目的函数
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

// 定义断点函数：弱引用错误处理函数
BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

// 定义宏：报告弱引用错误
#define REPORT_WEAK_ERROR(format, ...) do { \
    // 根据调试选项决定是否显示断点消息
    const char *breakMessage = DebugWeakErrors == Fatal ? "" : " Break on objc_weak_error to debug."; \
    // 报告错误信息
    OBJC_DEBUG_OPTION_REPORT_ERROR(DebugWeakErrors, format "%s", __VA_ARGS__, breakMessage); \
    // 调用弱引用错误函数
    objc_weak_error(); \
} while(0)

// 静态函数：处理损坏的弱引用表
static void bad_weak_table(weak_entry_t *entries)
{
    // 报告致命错误：弱引用表损坏
    _objc_fatal("bad weak table at %p. This may be a runtime bug or a "
                "memory error somewhere else.", entries);
}

/** 
 * Unique hash function for object pointers only.
 * 
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 */
// 仅用于对象指针的唯一哈希函数
// 参数key：对象指针
// 返回：指针的无大小限制哈希值
static inline uintptr_t hash_pointer(objc_object *key) {
    // 将对象指针转换为整数并计算哈希值
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
// 仅用于弱对象指针的唯一哈希函数
// 参数key：弱对象指针
// 返回：指针的无大小限制哈希值
static inline uintptr_t w_hash_pointer(objc_object **key) {
    // 将弱对象指针转换为整数并计算哈希值
    return ptr_hash((uintptr_t)key);
}

/** 
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 
 * @param entry Weak pointer hash set for a particular object.
 */
// 扩展条目的弱引用者哈希表：重新哈希每个弱引用者
// 参数entry：特定对象的弱指针哈希集合
// 不内联、已使用属性
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer)
{
    // 断言条目使用外联存储
    ASSERT(entry->out_of_line());

    // 获取旧表的大小
    size_t old_size = TABLE_SIZE(entry);
    // 计算新表的大小（如果旧表存在则翻倍，否则初始化为8）
    size_t new_size = old_size ? old_size * 2 : 8;

    // 保存旧的引用数量
    size_t num_refs = entry->num_refs;
    // 保存旧的弱引用者数组
    weak_referrer_t *old_refs = entry->referrers;
    // 设置新的掩码（新大小减1）
    entry->mask = new_size - 1;
    
    // 分配新的弱引用者数组（初始化为0）
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    // 重置引用数量
    entry->num_refs = 0;
    // 重置最大哈希位移
    entry->max_hash_displacement = 0;
    
    // 遍历旧数组，重新插入所有非nil的弱引用者
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        // 如果旧数组中的位置不为nil
        if (old_refs[i] != nil) {
            // 将弱引用者添加到新表中
            append_referrer(entry, old_refs[i]);
            // 减少剩余引用数量
            num_refs--;
        }
    }
    // Insert
    // 插入新的弱引用者
    append_referrer(entry, new_referrer);
    // 如果旧数组存在，释放它
    if (old_refs) free(old_refs);
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 *
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
// 将给定的弱引用者添加到条目的弱指针集合中
// 不执行重复检查（因为弱指针永远不会被添加到集合中两次）
// 参数entry：持有弱指针集合的条目
// 参数new_referrer：要添加的新弱指针
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer)
{
    // 如果条目使用内联存储
    if (! entry->out_of_line()) {
        // Try to insert inline.
        // 尝试内联插入
        // 遍历内联数组，查找空位置
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            // 如果找到空位置
            if (entry->inline_referrers[i] == nil) {
                // 将新弱引用者存储到该位置
                entry->inline_referrers[i] = new_referrer;
                // 返回
                return;
            }
        }

        // Couldn't insert inline. Allocate out of line.
        // 无法内联插入，分配外联存储
        // 分配新的弱引用者数组（大小为内联数组大小）
        weak_referrer_t *new_referrers = (weak_referrer_t *)
            calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        // 这个构造的表是无效的，但grow_refs_and_insert会修复并重新哈希它
        // 将内联数组的内容复制到新数组
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        // 设置条目的弱引用者数组为新数组
        entry->referrers = new_referrers;
        // 设置引用数量为内联数组大小
        entry->num_refs = WEAK_INLINE_COUNT;
        // 设置外联标志
        entry->out_of_line_ness = REFERRERS_OUT_OF_LINE;
        // 设置掩码（内联数组大小减1）
        entry->mask = WEAK_INLINE_COUNT-1;
        // 重置最大哈希位移
        entry->max_hash_displacement = 0;
    }

    // 断言条目现在使用外联存储
    ASSERT(entry->out_of_line());

    // 如果引用数量达到表大小的3/4，需要扩展表
    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        // 调用扩展函数并插入新弱引用者
        return grow_refs_and_insert(entry, new_referrer);
    }
    // 计算新弱引用者的哈希值并应用掩码得到起始索引
    size_t begin = w_hash_pointer(new_referrer) & (entry->mask);
    // 当前索引从起始位置开始
    size_t index = begin;
    // 哈希位移初始化为0
    size_t hash_displacement = 0;
    // 使用开放寻址法查找空位置
    while (entry->referrers[index] != nil) {
        // 增加哈希位移
        hash_displacement++;
        // 移动到下一个位置（使用掩码包装）
        index = (index+1) & entry->mask;
        // 如果回到起始位置，说明表已满，报告错误
        if (index == begin) bad_weak_table(entry);
    }
    // 如果当前哈希位移大于最大哈希位移
    if (hash_displacement > entry->max_hash_displacement) {
        // 更新最大哈希位移
        entry->max_hash_displacement = hash_displacement;
    }
    // 获取找到位置的引用
    weak_referrer_t &ref = entry->referrers[index];
    // 将新弱引用者存储到该位置
    ref = new_referrer;
    // 增加引用数量
    entry->num_refs++;
}

/** 
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
// 从弱引用者集合中移除old_referrer（如果存在）
// 不移除重复项，因为重复项不应该存在
// TODO：如果old_referrer不存在，这很慢。这种情况会发生吗？
// 参数entry：持有弱引用者的条目
// 参数old_referrer：要移除的弱引用者
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    // 如果条目使用内联存储
    if (! entry->out_of_line()) {
        // 遍历内联数组，查找要移除的弱引用者
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            // 如果找到匹配的弱引用者
            if (entry->inline_referrers[i] == old_referrer) {
                // 将该位置设置为nil
                entry->inline_referrers[i] = nil;
                // 返回
                return;
            }
        }
        // 如果未找到，报告错误
        REPORT_WEAK_ERROR("Attempted to unregister unknown __weak variable "
                          "at %p. This is probably incorrect use of "
                          "objc_storeWeak() and objc_loadWeak().",
                          old_referrer);
        // 返回
        return;
    }

    // 计算旧弱引用者的哈希值并应用掩码得到起始索引
    size_t begin = w_hash_pointer(old_referrer) & (entry->mask);
    // 当前索引从起始位置开始
    size_t index = begin;
    // 哈希位移初始化为0
    size_t hash_displacement = 0;
    // 使用开放寻址法查找要移除的弱引用者
    while (entry->referrers[index] != old_referrer) {
        // 移动到下一个位置（使用掩码包装）
        index = (index+1) & entry->mask;
        // 如果回到起始位置，说明表已满，报告错误
        if (index == begin) bad_weak_table(entry);
        // 增加哈希位移
        hash_displacement++;
        // 如果哈希位移超过最大哈希位移
        if (hash_displacement > entry->max_hash_displacement) {
            // 报告错误：尝试注销未知的__weak变量
            REPORT_WEAK_ERROR("Attempted to unregister unknown __weak variable "
                              "at %p. This is probably incorrect use of "
                              "objc_storeWeak() and objc_loadWeak().",
                              old_referrer);
            // 返回
            return;
        }
    }
    // 将找到的位置设置为nil
    entry->referrers[index] = nil;
    // 减少引用数量
    entry->num_refs--;
}

/** 
 * Add new_entry to the object's table of weak references.
 * Does not check whether the referent is already in the table.
 */
// 将new_entry添加到对象的弱引用表中
// 不检查referent是否已在表中
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    // 获取弱引用条目数组
    weak_entry_t *weak_entries = weak_table->weak_entries;
    // 断言弱引用条目数组不为nil
    ASSERT(weak_entries != nil);

    // 计算新条目的referent的哈希值并应用掩码得到起始索引
    size_t begin = hash_pointer(new_entry->referent) & (weak_table->mask);
    // 当前索引从起始位置开始
    size_t index = begin;
    // 哈希位移初始化为0
    size_t hash_displacement = 0;
    // 使用开放寻址法查找空位置
    while (weak_entries[index].referent != nil) {
        // 移动到下一个位置（使用掩码包装）
        index = (index+1) & weak_table->mask;
        // 如果回到起始位置，说明表已满，报告错误
        if (index == begin) bad_weak_table(weak_entries);
        // 增加哈希位移
        hash_displacement++;
    }

    // 将新条目复制到找到的位置
    weak_entries[index] = *new_entry;
    // 增加条目数量
    weak_table->num_entries++;

    // 如果当前哈希位移大于最大哈希位移
    if (hash_displacement > weak_table->max_hash_displacement) {
        // 更新最大哈希位移
        weak_table->max_hash_displacement = hash_displacement;
    }
}


// 静态函数：调整弱引用表的大小
static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    // 获取旧表的大小
    size_t old_size = TABLE_SIZE(weak_table);

    // 保存旧的弱引用条目数组
    weak_entry_t *old_entries = weak_table->weak_entries;
    // 分配新的弱引用条目数组（初始化为0）
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));

    // 设置新的掩码（新大小减1）
    weak_table->mask = new_size - 1;
    // 设置新的弱引用条目数组
    weak_table->weak_entries = new_entries;
    // 重置最大哈希位移
    weak_table->max_hash_displacement = 0;
    // 重置条目数量（将由下面的weak_entry_insert恢复）
    weak_table->num_entries = 0;  // restored by weak_entry_insert below
    
    // 如果旧条目数组存在
    if (old_entries) {
        // 条目指针和结束指针
        weak_entry_t *entry;
        weak_entry_t *end = old_entries + old_size;
        // 遍历旧条目数组
        for (entry = old_entries; entry < end; entry++) {
            // 如果条目有referent（非空）
            if (entry->referent) {
                // 将条目插入到新表中
                weak_entry_insert(weak_table, entry);
            }
        }
        // 释放旧条目数组
        free(old_entries);
    }
}

// Grow the given zone's table of weak references if it is full.
// 如果给定区域的弱引用表已满，则扩展它
static void weak_grow_maybe(weak_table_t *weak_table)
{
    // 获取旧表的大小
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    // 如果至少3/4满，则扩展
    // 如果条目数量达到旧表大小的3/4
    if (weak_table->num_entries >= old_size * 3 / 4) {
        // 调整表大小（如果旧表存在则翻倍，否则初始化为64）
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
}

// Shrink the table if it is mostly empty.
// 如果表大部分为空，则收缩它
static void weak_compact_maybe(weak_table_t *weak_table)
{
    // 获取旧表的大小
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    // 如果大于1024个桶且最多1/16满，则收缩
    // 如果旧表大小大于等于1024且条目数量最多为旧表大小的1/16
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        // 调整表大小为旧表大小的1/8
        weak_resize(weak_table, old_size / 8);
        // leaves new table no more than 1/2 full
        // 使新表最多1/2满
    }
}


/**
 * Remove entry from the zone's table of weak references.
 */
// 从区域的弱引用表中移除条目
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    // 移除条目
    // 如果条目使用外联存储，释放弱引用者数组
    if (entry->out_of_line()) free(entry->referrers);
    // 将条目清零
    memset(entry, 0, sizeof(*entry));

    // 减少条目数量
    weak_table->num_entries--;

    // 可能收缩表
    weak_compact_maybe(weak_table);
}


/** 
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup.
 *
 * @param weak_table 
 * @param referent The object. Must not be nil.
 * 
 * @return The table of weak referrers to this object. 
 */
// 返回给定referent的弱引用表条目
// 如果没有referent的条目，返回NULL
// 执行查找操作
// 参数weak_table：弱引用表
// 参数referent：对象，不能为nil
// 返回：指向此对象的弱引用者表
weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent)
{
    // 断言referent不为nil
    ASSERT(referent);

    // 获取弱引用条目数组
    weak_entry_t *weak_entries = weak_table->weak_entries;

    // 如果弱引用条目数组不存在，返回nil
    if (!weak_entries) return nil;

    // 计算referent的哈希值并应用掩码得到起始索引
    size_t begin = hash_pointer(referent) & weak_table->mask;
    // 当前索引从起始位置开始
    size_t index = begin;
    // 哈希位移初始化为0
    size_t hash_displacement = 0;
    // 使用开放寻址法查找匹配的条目
    while (weak_table->weak_entries[index].referent != referent) {
        // 移动到下一个位置（使用掩码包装）
        index = (index+1) & weak_table->mask;
        // 如果回到起始位置，说明表已满，报告错误
        if (index == begin) bad_weak_table(weak_table->weak_entries);
        // 增加哈希位移
        hash_displacement++;
        // 如果哈希位移超过最大哈希位移，说明未找到
        if (hash_displacement > weak_table->max_hash_displacement) {
            // 返回nil
            return nil;
        }
    }
    
    // 返回找到的条目指针
    return &weak_table->weak_entries[index];
}

/** 
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 
 * @param weak_table The global weak table.
 * @param referent The object.
 * @param referrer The weak reference.
 */
// 注销已注册的弱引用
// 当referrer的存储即将消失但referent尚未死亡时使用
// （否则，稍后将referrer清零将是错误的内存访问）
// 如果referent/referrer不是当前活动的弱引用，则不执行任何操作
// 不会将referrer清零
// FIXME：当前需要传入旧的referent值（不好）
// FIXME：如果referrer被收集，注销应该是自动的
// 参数weak_table：全局弱引用表
// 参数referent：对象
// 参数referrer：弱引用
void
weak_unregister_no_lock(weak_table_t *weak_table, id referent_id, 
                        id *referrer_id)
{
    // 将referent_id转换为objc_object指针
    objc_object *referent = (objc_object *)referent_id;
    // 将referrer_id转换为objc_object指针的指针
    objc_object **referrer = (objc_object **)referrer_id;

    // 弱引用条目指针
    weak_entry_t *entry;

    // 如果referent为nil，直接返回
    if (!referent) return;

    // 如果找到referent的条目
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        // 从条目中移除弱引用者
        remove_referrer(entry, referrer);
        // 初始化空标志为true
        bool empty = true;
        // 如果条目使用外联存储且引用数量不为0
        if (entry->out_of_line()  &&  entry->num_refs != 0) {
            // 条目非空
            empty = false;
        }
        else {
            // 遍历内联数组，检查是否有非nil的弱引用者
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                // 如果找到非nil的弱引用者
                if (entry->inline_referrers[i]) {
                    // 条目非空
                    empty = false; 
                    // 跳出循环
                    break;
                }
            }
        }

        // 如果条目为空
        if (empty) {
            // 从弱引用表中移除条目
            weak_entry_remove(weak_table, entry);
        }
    }

    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
    // 不要设置*referrer = nil。objc_storeWeak()要求值不改变
}

/** 
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 */
// 注册新的（对象，弱指针）对。如果不存在，创建新的弱对象条目
// 参数weak_table：全局弱引用表
// 参数referent：弱引用指向的对象
// 参数referrer：弱指针地址
id 
weak_register_no_lock(weak_table_t *weak_table, id referent_id, 
                      id *referrer_id, WeakRegisterDeallocatingOptions deallocatingOptions)
{
    // 将referent_id转换为objc_object指针
    objc_object *referent = (objc_object *)referent_id;
    // 将referrer_id转换为objc_object指针的指针
    objc_object **referrer = (objc_object **)referrer_id;

    // 如果referent是标记指针或nil，直接返回
    if (_objc_isTaggedPointerOrNil(referent)) return referent_id;

    // ensure that the referenced object is viable
    // 确保被引用的对象是有效的
    // 如果需要检查是否正在释放
    if (deallocatingOptions == ReturnNilIfDeallocating ||
        deallocatingOptions == CrashIfDeallocating) {
        // 是否正在释放的标志
        bool deallocating;
        // 如果对象没有自定义retain/release
        if (!referent->ISA()->hasCustomRR()) {
            // 直接检查根类是否正在释放
            deallocating = referent->rootIsDeallocating();
        }
        else {
            // Use lookUpImpOrForward so we can avoid the assert in
            // class_getInstanceMethod, since we intentionally make this
            // callout with the lock held.
            // 使用lookUpImpOrForward以便我们可以避免class_getInstanceMethod中的断言
            // 因为我们有意在持有锁的情况下进行此调用
            // 查找allowsWeakReference方法的实现
            auto allowsWeakReference = (BOOL(*)(objc_object *, SEL))
            lookUpImpOrForwardTryCache((id)referent, @selector(allowsWeakReference),
                                       referent->getIsa());
            // 如果实现是消息转发
            if ((IMP)allowsWeakReference == _objc_msgForward) {
                // 返回nil
                return nil;
            }
            // 调用allowsWeakReference方法，取反得到是否正在释放
            deallocating =
            ! (*allowsWeakReference)(referent, @selector(allowsWeakReference));
        }

        // 如果对象正在释放
        if (deallocating) {
            // 如果需要崩溃
            if (deallocatingOptions == CrashIfDeallocating) {
                // 报告致命错误：无法形成弱引用
                _objc_fatal("Cannot form weak reference to instance (%p) of "
                            "class %s. It is possible that this object was "
                            "over-released, or is in the process of deallocation.",
                            (void*)referent, object_getClassName((id)referent));
            } else {
                // 否则返回nil
                return nil;
            }
        }
    }

    // now remember it and where it is being stored
    // 现在记住它以及它被存储的位置
    // 弱引用条目指针
    weak_entry_t *entry;
    // 如果找到referent的条目
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        // 将弱引用者添加到条目中
        append_referrer(entry, referrer);
    } 
    else {
        // 否则创建新条目
        weak_entry_t new_entry(referent, referrer);
        // 可能扩展表
        weak_grow_maybe(weak_table);
        // 将新条目插入到表中
        weak_entry_insert(weak_table, &new_entry);
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.
    // 不要设置*referrer。objc_storeWeak()要求值不改变

    // 返回referent_id
    return referent_id;
}


// 如果启用调试模式
#if DEBUG
// 检查对象是否在弱引用表中注册（无锁版本）
bool
weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id) 
{
    // 查找referent的条目，如果找到则返回true，否则返回false
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 
 * @param weak_table 
 * @param referent The object being deallocated. 
 */
// 由dealloc调用；将所有指向提供对象的弱指针清零，以便它们不能再被使用
// 参数weak_table：弱引用表
// 参数referent：正在被释放的对象
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    // 将referent_id转换为objc_object指针
    objc_object *referent = (objc_object *)referent_id;

    // 查找referent的条目
    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    // 如果条目为nil
    if (entry == nil) {
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        // XXX不应该发生，但在CF/objc不匹配时会发生
        // 直接返回
        return;
    }

    // zero out references
    // 清零引用
    // 弱引用者数组指针和数量
    weak_referrer_t *referrers;
    size_t count;
    
    // 如果条目使用外联存储
    if (entry->out_of_line()) {
        // 使用外联数组
        referrers = entry->referrers;
        // 数量为表的大小
        count = TABLE_SIZE(entry);
    } 
    else {
        // 否则使用内联数组
        referrers = entry->inline_referrers;
        // 数量为内联数组大小
        count = WEAK_INLINE_COUNT;
    }
    
    // 遍历所有弱引用者
    for (size_t i = 0; i < count; ++i) {
        // 获取弱引用者指针
        objc_object **referrer = referrers[i];
        // 如果弱引用者不为nil
        if (referrer) {
            // 如果弱引用者指向referent
            if (*referrer == referent) {
                // 将弱引用者设置为nil
                *referrer = nil;
            }
            // 否则如果弱引用者指向其他对象
            else if (*referrer) {
                // 报告错误：弱变量持有错误的对象
                REPORT_WEAK_ERROR("__weak variable at %p holds %p instead of %p. "
                                  "This is probably incorrect use of "
                                  "objc_storeWeak() and objc_loadWeak().",
                                  referrer, (void*)*referrer, (void*)referent);
            }
        }
    }
    
    // 从弱引用表中移除条目
    weak_entry_remove(weak_table, entry);
}

