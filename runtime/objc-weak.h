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

// 头文件保护：防止重复包含
#ifndef _OBJC_WEAK_H_
// 定义头文件保护宏
#define _OBJC_WEAK_H_

// 包含Objective-C基础头文件
#include <objc/objc.h>
// 包含Objective-C配置头文件
#include "objc-config.h"

// 开始C语言链接声明
__BEGIN_DECLS

/*
The weak table is a hash table governed by a single spin lock.
An allocated blob of memory, most often an object, but under GC any such 
allocation, may have its address stored in a __weak marked storage location 
through use of compiler generated write-barriers or hand coded uses of the 
register weak primitive. Associated with the registration can be a callback 
block for the case when one of the allocated chunks of memory is reclaimed. 
The table is hashed on the address of the allocated memory.  When __weak 
marked memory changes its reference, we count on the fact that we can still 
see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of 
all locations where this address is currently being stored.
 
For ARC, we also keep track of whether an arbitrary object is being 
deallocated by briefly placing it in the table just prior to invoking 
dealloc, and removing it via objc_clear_deallocating just prior to memory 
reclamation.

*/

// The address of a __weak variable.
// These pointers are stored disguised so memory analysis tools
// don't see lots of interior pointers from the weak table into objects.
// __weak变量的地址
// 这些指针被伪装存储，以便内存分析工具不会看到从弱表到对象的大量内部指针
// 定义弱引用者类型：伪装的对象指针
typedef DisguisedPtr<objc_object *> weak_referrer_t;

// 如果是64位平台
#if __LP64__
// 定义指针减去2的值（用于位域，62位用于存储引用计数）
#define PTR_MINUS_2 62
#else
// 如果是32位平台，定义指针减去2的值（30位用于存储引用计数）
#define PTR_MINUS_2 30
#endif

/**
 * The internal structure stored in the weak references table. 
 * It maintains and stores
 * a hash set of weak references pointing to an object.
 * If out_of_line_ness != REFERRERS_OUT_OF_LINE then the set
 * is instead a small inline array.
 */
// 弱引用表中存储的内部结构
// 它维护并存储指向对象的弱引用哈希集合
// 如果out_of_line_ness != REFERRERS_OUT_OF_LINE，则集合是一个小的内联数组
// 定义内联弱引用数组的大小
#define WEAK_INLINE_COUNT 4

// out_of_line_ness field overlaps with the low two bits of inline_referrers[1].
// inline_referrers[1] is a DisguisedPtr of a pointer-aligned address.
// The low two bits of a pointer-aligned DisguisedPtr will always be 0b00
// (disguised nil or 0x80..00) or 0b11 (any other address).
// Therefore out_of_line_ness == 0b10 is used to mark the out-of-line state.
// out_of_line_ness字段与inline_referrers[1]的低两位重叠
// inline_referrers[1]是指针对齐地址的DisguisedPtr
// 指针对齐的DisguisedPtr的低两位总是0b00（伪装的nil或0x80..00）或0b11（任何其他地址）
// 因此out_of_line_ness == 0b10用于标记外联状态
// 定义外联状态标志值
#define REFERRERS_OUT_OF_LINE 2

// 弱引用条目结构体：存储指向某个对象的所有弱引用
struct weak_entry_t {
    // 被弱引用的对象（伪装指针）
    DisguisedPtr<objc_object> referent;
    // 联合体：根据是否外联使用不同的存储方式
    union {
        // 外联结构：使用哈希表存储弱引用
        struct {
            // 弱引用者数组（哈希表）
            weak_referrer_t *referrers;
            // 外联标志位（2位）
            uintptr_t        out_of_line_ness : 2;
            // 弱引用数量（PTR_MINUS_2位）
            uintptr_t        num_refs : PTR_MINUS_2;
            // 哈希表掩码（用于计算索引）
            uintptr_t        mask;
            // 最大哈希位移（用于优化查找）
            uintptr_t        max_hash_displacement;
        };
        // 内联结构：使用小数组存储弱引用
        struct {
            // out_of_line_ness field is low bits of inline_referrers[1]
            // out_of_line_ness字段是inline_referrers[1]的低位
            // 内联弱引用数组（最多WEAK_INLINE_COUNT个）
            weak_referrer_t  inline_referrers[WEAK_INLINE_COUNT];
        };
    };

    // 检查是否使用外联存储
    bool out_of_line() {
        // 返回外联标志是否等于外联状态值
        return (out_of_line_ness == REFERRERS_OUT_OF_LINE);
    }

    // 赋值运算符：复制另一个弱引用条目
    weak_entry_t& operator=(const weak_entry_t& other) {
        // 使用memcpy复制整个结构体
        memcpy(this, &other, sizeof(other));
        // 返回自身引用
        return *this;
    }

    // 构造函数：创建新的弱引用条目
    weak_entry_t(objc_object *newReferent, objc_object **newReferrer)
        // 初始化被引用的对象
        : referent(newReferent)
    {
        // 将第一个弱引用者存储到内联数组的第一个位置
        inline_referrers[0] = newReferrer;
        // 将内联数组的其余位置初始化为nil
        for (int i = 1; i < WEAK_INLINE_COUNT; i++) {
            inline_referrers[i] = nil;
        }
    }
};

/**
 * The global weak references table. Stores object ids as keys,
 * and weak_entry_t structs as their values.
 */
// 全局弱引用表：以对象ID为键，weak_entry_t结构体为值
// 弱引用表结构体
struct weak_table_t {
    // 弱引用条目数组（哈希表）
    weak_entry_t *weak_entries;
    // 条目数量
    size_t    num_entries;
    // 哈希表掩码（用于计算索引）
    uintptr_t mask;
    // 最大哈希位移（用于优化查找）
    uintptr_t max_hash_displacement;
};

// 弱引用注册时的释放选项枚举
enum WeakRegisterDeallocatingOptions {
    // 如果对象正在释放，返回nil
    ReturnNilIfDeallocating,
    // 如果对象正在释放，崩溃
    CrashIfDeallocating,
    // 不检查是否正在释放
    DontCheckDeallocating
};

/// Retrieve the entry for a given object from the corresponding table.
// 从对应的表中检索给定对象的条目
weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent);

/// Adds an (object, weak pointer) pair to the weak table.
// 向弱引用表添加（对象，弱指针）对
id weak_register_no_lock(weak_table_t *weak_table, id referent,
                         id *referrer, WeakRegisterDeallocatingOptions deallocatingOptions);

/// Removes an (object, weak pointer) pair from the weak table.
// 从弱引用表中移除（对象，弱指针）对
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

// 如果启用调试模式
#if DEBUG
/// Returns true if an object is weakly referenced somewhere.
// 如果对象在某处被弱引用，返回true
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent);
#endif

/// Called on object destruction. Sets all remaining weak pointers to nil.
// 在对象销毁时调用：将所有剩余的弱指针设置为nil
void weak_clear_no_lock(weak_table_t *weak_table, id referent);

// 结束C语言链接声明
__END_DECLS

// 结束头文件保护
#endif /* _OBJC_WEAK_H_ */
