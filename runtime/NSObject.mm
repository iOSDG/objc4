/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
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

// 包含Objective-C运行时私有头文件，提供运行时内部实现所需的定义和函数
#include "objc-private.h"
// 包含NSObject类的头文件，定义NSObject类的基本接口
#include "NSObject.h"

// 包含弱引用相关的头文件，提供弱引用机制的实现
#include "objc-weak.h"
// 包含初始化包装器头文件，提供初始化相关的辅助功能
#include "InitWrappers.h"

// 包含内存分配相关的头文件，提供malloc相关函数
#include <malloc/malloc.h>
// 包含标准整数类型定义头文件，提供uint32_t等类型定义
#include <stdint.h>
// 包含标准布尔类型定义头文件，提供bool类型定义
#include <stdbool.h>
// 包含动态链接器头文件，提供dyld相关功能
#include <mach-o/dyld.h>
// 包含符号表头文件，提供nlist结构定义
#include <mach-o/nlist.h>
// 包含系统类型定义头文件，提供基本系统类型
#include <sys/types.h>
// 包含Block运行时头文件，提供Block相关功能
#include <Block.h>
// 包含C++标准库map容器头文件，提供map数据结构
#include <map>
// 包含NSObject内部实现头文件，提供NSObject的内部实现细节
#include "NSObject-internal.h"
// 包含NSObject私有实现头文件，提供NSObject的私有实现细节
#include "NSObject-private.h"

// 包含Mach内核头文件，提供Mach系统调用接口
#include <mach/mach.h>
// 包含内存管理头文件，提供内存映射相关函数如mprotect
#include <sys/mman.h>

// 包含操作系统特性私有头文件，提供特性检测功能
#include <os/feature_private.h>

// 声明NSInvocation接口，用于方法调用封装
@interface NSInvocation
// 声明selector方法，返回方法选择器
- (SEL)selector;
@end

// 导出自动释放池页数据中magic字段的偏移量，用于调试工具定位magic字段位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_magic_offset  = __builtin_offsetof(AutoreleasePoolPageData, magic);
// 导出自动释放池页数据中next字段的偏移量，用于调试工具定位next指针位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_next_offset   = __builtin_offsetof(AutoreleasePoolPageData, next);
// 导出自动释放池页数据中thread字段的偏移量，用于调试工具定位线程信息位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_thread_offset = __builtin_offsetof(AutoreleasePoolPageData, thread);
// 导出自动释放池页数据中parent字段的偏移量，用于调试工具定位父页面指针位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_parent_offset = __builtin_offsetof(AutoreleasePoolPageData, parent);
// 导出自动释放池页数据中child字段的偏移量，用于调试工具定位子页面指针位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_child_offset  = __builtin_offsetof(AutoreleasePoolPageData, child);
// 导出自动释放池页数据中depth字段的偏移量，用于调试工具定位深度信息位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_depth_offset  = __builtin_offsetof(AutoreleasePoolPageData, depth);
// 导出自动释放池页数据中hiwat字段的偏移量，用于调试工具定位高水位标记位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_hiwat_offset  = __builtin_offsetof(AutoreleasePoolPageData, hiwat);
// 导出自动释放池页数据结构的结束位置偏移量，即数据区域开始位置
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_begin_offset  = sizeof(AutoreleasePoolPageData);
// 如果支持自动释放池指针去重功能，则使用指针掩码
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
// 导出自动释放池页指针掩码，用于指针去重功能
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = AutoreleasePoolPageData::AutoreleasePoolEntry::pointerMask;
#else
// 如果不支持指针去重，则使用全1掩码（表示所有位都有效）
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = ~(uintptr_t)0;
#endif
// 导出Objective-C类ABI版本号，设置为最大支持的ABI版本
OBJC_EXTERN const uint32_t objc_class_abi_version = OBJC_CLASS_ABI_VERSION_MAX;

/***********************************************************************
* Weak ivar support
**********************************************************************/

// 默认的分配失败处理函数，当对象分配失败时被调用
static id defaultBadAllocHandler(Class cls)
{
    // 调用致命错误函数，输出分配失败的错误信息，包含类名
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                // 获取类的日志名称用于错误输出
                cls->nameForLogging());
}

// 声明并初始化分配失败处理函数指针，使用指针认证保护，初始指向默认处理函数
id(* ptrauth_badAllocHandler badAllocHandler)(Class) = &defaultBadAllocHandler;

// 调用分配失败处理函数的公共接口
id _objc_callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    // 调用当前设置的分配失败处理函数，传入类对象
    return (*badAllocHandler)(cls);
}

// 设置自定义的分配失败处理函数
void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    // 将分配失败处理函数指针更新为新的处理函数
    badAllocHandler = newHandler;
}

// Support for making direct calls to swift_retain and swift_release instead of
// going through objc_msgSend and SwiftObject's retain/release methods.
//
// We use delay-init to refer to swift_retain/release, since we don't want to
// force libswiftCore to load. Delay-init adds a tiny bit of overhead to each
// call, which is normally fine, but refcounting is performance-critical.
// Instead of calling the functions directly, we lazily initialize function
// pointers. By initializing the function pointers with functions that perform
// the lazy initialization, we get minimal overhead once the functions have been
// looked up.
//
// Delay-init rewrites the references to swift_retain/release to go through a
// function call, which means it needs the containing function to have a frame.
// These initialization functions are small/simple enough that the compiler
// normally makes them frameless, with a tail call to swiftRetain/Release. We
// use empty asm volatile statements to force the calls to not be tail calls,
// thus forcing the initialization functions to have frames. These functions
// only run once (or, in the event of a perfect thread race, a handful of times)
// so performance isn't critical for that.
// 前向声明：初始化Swift引用计数然后调用retain的函数
static id _initializeSwiftRefcountingThenCallRetain(id objc);
// 前向声明：初始化Swift引用计数然后调用release的函数
static void _initializeSwiftRefcountingThenCallRelease(id objc);

// 使用指针认证保护的全局原子函数指针，用于Swift对象的retain操作，初始指向初始化函数
PtrauthGlobalAtomicFunction<id(*)(id)> swiftRetain{&_initializeSwiftRefcountingThenCallRetain};
// 使用指针认证保护的全局原子函数指针，用于Swift对象的release操作，初始指向初始化函数
PtrauthGlobalAtomicFunction<void(*)(id)> swiftRelease{&_initializeSwiftRefcountingThenCallRelease};

// 声明外部C函数：Swift对象的retain函数
extern "C" id swift_retain(id);
// 声明外部C函数：Swift对象的release函数
extern "C" void swift_release(id);

// 强制内联：初始化Swift引用计数函数指针
ALWAYS_INLINE
static void _initializeSwiftRefcounting() {
    // 使用宽松内存序将swift_retain函数存储到函数指针中
    swiftRetain.store(swift_retain, memory_order_relaxed);
    // 断言验证函数指针已正确设置
    ASSERT(swiftRetain.load(memory_order_relaxed));
    // 使用宽松内存序将swift_release函数存储到函数指针中
    swiftRelease.store(swift_release, memory_order_relaxed);
    // 断言验证函数指针已正确设置
    ASSERT(swiftRelease.load(memory_order_relaxed));
}

// 初始化Swift引用计数然后调用retain的静态函数
static id _initializeSwiftRefcountingThenCallRetain(id objc) {
    // 首先初始化Swift引用计数函数指针
    _initializeSwiftRefcounting();
    // 加载函数指针并调用retain函数，获取返回值
    id ret = swiftRetain.load(memory_order_relaxed)(objc);
    // 空的汇编语句，防止编译器将调用优化为尾调用，确保函数有栈帧
    asm volatile ("");
    // 返回retain后的对象
    return ret;
}

// 初始化Swift引用计数然后调用release的静态函数
static void _initializeSwiftRefcountingThenCallRelease(id objc) {
    // 首先初始化Swift引用计数函数指针
    _initializeSwiftRefcounting();
    // 加载函数指针并调用release函数
    swiftRelease.load(memory_order_relaxed)(objc);
    // Delay-init rewrites the references to swift_retain/release to go through
    // a function call, which means it needs this function to have a frame, but
    // it runs too late to force one. Instead, we force it with this empty asm
    // statement, which prevents the above call from being tail called.
    // 空的汇编语句，防止编译器将调用优化为尾调用，确保函数有栈帧
    asm volatile ("");
}

// objc命名空间，用于组织Objective-C运行时相关的代码
namespace objc {
    // 声明页面计数警告变量，用于监控自动释放池的深度
    extern int PageCountWarning;
}

// 匿名命名空间，用于定义文件内部使用的符号
namespace {

// 原子计数器，记录自动释放池故障次数
_Atomic uint32_t numFaults = 0;

// The order of these bits is important.
// 定义侧边表弱引用标志位（最低位）
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
// 定义侧边表正在释放标志位（第1位，在弱引用位的MSB方向）
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
// 定义侧边表引用计数单位（第2位，在释放位的MSB方向）
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
// 定义侧边表引用计数固定标志位（最高位）
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))

// 定义引用计数在侧边表中的右移位数，用于提取引用计数值
#define SIDE_TABLE_RC_SHIFT 2
// 定义侧边表标志位掩码，用于提取标志位
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

// 模板特化：当同时有旧值和新值时的加锁函数
template<>
void SideTable::lockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    // 同时锁定两个侧边表的自旋锁，按地址顺序锁定以避免死锁
    spinlock_t::lockTwo(&lock1->slock, &lock2->slock);
}

// 模板特化：当只有旧值没有新值时的加锁函数
template<>
void SideTable::lockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    // 只锁定旧值对应的侧边表
    lock1->lock();
}

// 模板特化：当只有新值没有旧值时的加锁函数
template<>
void SideTable::lockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    // 只锁定新值对应的侧边表
    lock2->lock();
}

// 模板特化：当同时有旧值和新值时的解锁函数
template<>
void SideTable::unlockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    // 同时解锁两个侧边表的自旋锁
    spinlock_t::unlockTwo(&lock1->slock, &lock2->slock);
}

// 模板特化：当只有旧值没有新值时的解锁函数
template<>
void SideTable::unlockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    // 只解锁旧值对应的侧边表
    lock1->unlock();
}

// 模板特化：当只有新值没有旧值时的解锁函数
template<>
void SideTable::unlockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    // 只解锁新值对应的侧边表
    lock2->unlock();
}

// 静态初始化侧边表映射，使用显式初始化包装器延迟初始化
static objc::ExplicitInit<StripedMap<SideTable>> SideTablesMap;
// 导出侧边表映射的地址，供调试工具使用
OBJC_EXTERN void *const objc_debug_side_tables_map = &SideTablesMap;

// 获取侧边表映射的引用
static StripedMap<SideTable>& SideTables() {
    // 返回已初始化的侧边表映射
    return SideTablesMap.get();
}

// anonymous namespace
};

// 锁定所有侧边表，用于全局操作
void SideTableLockAll() {
    // 调用侧边表映射的锁定所有函数
    SideTables().lockAll();
}

// 解锁所有侧边表，用于全局操作
void SideTableUnlockAll() {
    // 调用侧边表映射的解锁所有函数
    SideTables().unlockAll();
}

// 强制重置所有侧边表，用于清理操作
void SideTableForceResetAll() {
    // 调用侧边表映射的强制重置所有函数
    SideTables().forceResetAll();
}

// 根据索引获取侧边表的自旋锁指针
spinlock_t *SideTableGetLock(unsigned n) {
    // 尝试获取指定索引的侧边表条目
    if (auto *entry = SideTables().getLock(n))
        // 返回该条目的自旋锁指针
        return &entry->slock;
    // 如果获取失败，返回空指针
    return nullptr;
}

// Call out to the _setWeaklyReferenced method on obj, if implemented.
// 调用对象的_setWeaklyReferenced方法（如果已实现），用于通知对象它被弱引用了
static void callSetWeaklyReferenced(id obj) {
    // 如果对象为空，直接返回
    if (!obj)
        return;

    // 获取对象的类
    Class cls = obj->getIsa();

    // 如果类有自定义的retain/release实现且对象不是类对象，则调用_setWeaklyReferenced方法
    if (slowpath(cls->hasCustomRR() && !object_isClass(obj))) {
        // 断言类已经初始化或正在初始化
        ASSERT(((objc_class *)cls)->isInitializing() || ((objc_class *)cls)->isInitialized());
        // 获取_setWeaklyReferenced方法的实现
        void (*setWeaklyReferenced)(id, SEL) = (void(*)(id, SEL))
        class_getMethodImplementation(cls, @selector(_setWeaklyReferenced));
        // 如果方法实现不是消息转发，则调用该方法
        if ((IMP)setWeaklyReferenced != _objc_msgForward) {
          // 调用_setWeaklyReferenced方法通知对象
          (*setWeaklyReferenced)(obj, @selector(_setWeaklyReferenced));
        }
    }
}

//
// The -fobjc-arc flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//

// 保留Block对象，增加Block的引用计数
id objc_retainBlock(id x) {
    // 调用Block的复制函数，增加引用计数并返回
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

// 判断对象是否应该被释放，当前实现总是返回YES
BOOL objc_should_deallocate(id object) {
    // 返回YES表示对象应该被释放
    return YES;
}

// 先保留对象再自动释放，返回自动释放后的对象
id
objc_retain_autorelease(id obj)
{
    // 先保留对象（增加引用计数），然后将其加入自动释放池
    return objc_autorelease(objc_retain(obj));
}


// 存储强引用，原子性地更新指针位置的值
void
objc_storeStrong(id *location, id obj)
{
    // 保存当前位置的旧值
    id prev = *location;
    // 如果新值和旧值相同，直接返回，无需操作
    if (obj == prev) {
        return;
    }

// 根据指针宽度定义坏对象标记值（用于检测内存错误）
#if __INTPTR_WIDTH__ == 32
// 32位系统下的坏对象标记
#define BAD_OBJECT ((id)0xbad0)
#else
// 64位系统下的坏对象标记
#define BAD_OBJECT ((id)0x400000000000bad0)
#endif
    // 先将位置设置为坏对象标记，用于检测并发访问错误
    *(volatile id *)location = BAD_OBJECT;

    // 保留新对象（增加引用计数）
    objc_retain(obj);
    // 将新对象存储到位置
    *location = obj;
    // 释放旧对象（减少引用计数）
    objc_release(prev);
}

// Scan all weak references tables and check them for integrity. If any weak
// reference is found whose value doesn't point back to the object it's
// associated with, this will log an error. Returns true if any problem was
// found, false if the tables passed the check.
// 扫描所有弱引用表并检查其完整性，如果发现任何弱引用的值不指向其关联的对象，将记录错误
// 返回true表示发现问题，false表示检查通过
static bool weakTableScan() {
    // 初始化问题标志为false
    bool foundProblem = false;
    // 遍历所有侧边表
    SideTables().forEach([&](SideTable &table) {
        // 锁定当前侧边表
        table.lock();

        // 获取弱引用表的掩码
        auto mask = table.weak_table.mask;
        // 如果掩码不为0，说明有弱引用条目
        if (mask) {
            // 遍历所有弱引用条目
            for (uintptr_t i = 0; i <= mask; i++) {
                // 获取当前弱引用条目
                auto &entry = table.weak_table.weak_entries[i];
                // 根据条目类型获取引用者数组（行外或行内）
                auto *referrers = entry.out_of_line() ? entry.referrers : entry.inline_referrers;
                // 根据条目类型获取引用者数量
                uintptr_t count = entry.out_of_line() ? entry.mask + 1 : WEAK_INLINE_COUNT;
                // 获取被引用对象
                objc_object *referent = entry.referent;
                // 如果被引用对象为空，跳过
                if (!referent) continue;

                // 遍历所有引用者
                for (uintptr_t j = 0; j < count; j++) {
                    // 获取当前引用者指针
                    objc_object **referrer = referrers[j];
                    // 如果引用者指针为空，跳过
                    if (!referrer) continue;

                    // 获取引用者当前指向的值
                    objc_object *currentValue = *referrer;
                    // 如果当前值与被引用对象不匹配，说明有问题
                    if (referent != currentValue) {
                        // 记录错误信息（立即记录并在崩溃时记录）
                        _objc_inform_now_and_on_crash("Weak reference at %p contains %p, should contain %p", referrer, currentValue, referent);
                        // 标记发现问题
                        foundProblem = true;
                    }
                }
            }
        }

        // 解锁当前侧边表
        table.unlock();
    });
    // 返回是否发现问题
    return foundProblem;
}

// 弱引用扫描线程函数，在后台持续扫描弱引用表的完整性
static void *weakTableScanThread(void *) {
    // 设置线程名称为"ObjC weak reference scanner"
    pthread_setname_np("ObjC weak reference scanner");

    // 初始化睡眠间隔为1毫秒（1000000纳秒）
    struct timespec sleepInterval = { 0, 1000000 };
    // 尝试从环境变量获取扫描间隔
    char *intervalStr = getenv("OBJC_DEBUG_SCAN_WEAK_TABLES_INTERVAL_NANOSECONDS");
    // 如果环境变量存在，使用环境变量中的值
    if (intervalStr) {
        // 将字符串转换为纳秒数
        unsigned long long nanos = strtoull(intervalStr, NULL, 10);
        // 计算纳秒部分（取模1秒）
        sleepInterval.tv_nsec = nanos % 1000000000;
        // 计算秒部分
        sleepInterval.tv_sec = nanos / 1000000000;
    }

    // 无限循环，持续扫描
    while (true) {
        // 睡眠指定间隔
        nanosleep(&sleepInterval, NULL);
        // 执行弱引用表扫描
        bool failed = weakTableScan();
        // 如果扫描发现问题，终止程序
        if (failed)
            _objc_fatal("Weak table scan detected a problem");
    }
}

// 启动弱引用扫描线程
static void startWeakTableScan() {
    // 输出信息，表示开始后台扫描弱引用
    _objc_inform("Starting background scan of weak references.");
    // 声明线程变量
    pthread_t thread;
    // 创建弱引用扫描线程
    int ret = pthread_create(&thread, nullptr, weakTableScanThread, nullptr);
    // 如果创建失败，终止程序
    if (ret != 0)
        _objc_fatal("pthread_create failed with error %d (%s)", ret, strerror(ret));
    // 将线程设置为分离状态，线程结束时自动清理资源
    pthread_detach(thread);
}
// Update a weak variable.
// If HaveOld is true, the variable has an existing value 
//   that needs to be cleaned up. This value might be nil.
// If HaveNew is true, there is a new value that needs to be 
//   assigned into the variable. This value might be nil.
// If CrashIfDeallocating is true, the process is halted if newObj is 
//   deallocating or newObj's class does not support weak references. 
//   If CrashIfDeallocating is false, nil is stored instead.
// 更新弱引用变量的枚举，定义是否在对象正在释放时崩溃
enum CrashIfDeallocating {
    // 不崩溃，存储nil
    DontCrashIfDeallocating = false, 
    // 崩溃，终止程序
    DoCrashIfDeallocating = true
};
// 模板函数：更新弱引用变量
// haveOld: 是否有旧值需要清理
// haveNew: 是否有新值需要赋值
// crashIfDeallocating: 如果新对象正在释放是否崩溃
template <HaveOld haveOld, HaveNew haveNew,
          enum CrashIfDeallocating crashIfDeallocating>
static id 
storeWeak(id *location, objc_object *newObj)
{
    // 断言：必须有旧值或新值
    ASSERT(haveOld  ||  haveNew);
    // 如果没有新值，新对象必须为nil
    if (!haveNew) ASSERT(newObj == nil);

    // 记录之前初始化的类，用于避免重复初始化
    Class previouslyInitializedClass = nil;
    // 旧对象
    id oldObj;
    // 旧对象对应的侧边表
    SideTable *oldTable;
    // 新对象对应的侧边表
    SideTable *newTable;

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
    // 重试标签：如果旧值在我们操作期间发生变化，需要重试
 retry:
    // 如果有旧值，获取旧对象和对应的侧边表
    if (haveOld) {
        // 读取当前位置的值作为旧对象
        oldObj = *location;
        // 获取旧对象对应的侧边表
        oldTable = &SideTables()[oldObj];
    } else {
        // 没有旧值，旧表为空
        oldTable = nil;
    }
    // 如果有新值，获取新对象对应的侧边表
    if (haveNew) {
        // 获取新对象对应的侧边表
        newTable = &SideTables()[newObj];
    } else {
        // 没有新值，新表为空
        newTable = nil;
    }

    // 根据是否有旧值和新值，锁定相应的侧边表
    SideTable::lockTwo<haveOld, haveNew>(oldTable, newTable);

    // 如果有旧值，但位置的值已经改变（被其他线程修改），需要重试
    if (haveOld  &&  *location != oldObj) {
        // 解锁侧边表
        SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
        // 跳转到重试标签
        goto retry;
    }

    // Prevent a deadlock between the weak reference machinery
    // and the +initialize machinery by ensuring that no 
    // weakly-referenced object has an un-+initialized isa.
    // 防止弱引用机制和+initialize机制之间的死锁，确保没有弱引用的对象有未初始化的isa
    if (haveNew  &&  newObj) {
        // 获取新对象的类
        Class cls = newObj->getIsa();
        // 如果类不是之前初始化的类，且类尚未初始化
        if (cls != previouslyInitializedClass  &&  
            !((objc_class *)cls)->isInitialized()) 
        {
            // 解锁侧边表，因为初始化可能需要获取其他锁
            SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
            // 初始化类
            class_initialize(cls, (id)newObj);

            // If this class is finished with +initialize then we're good.
            // If this class is still running +initialize on this thread 
            // (i.e. +initialize called storeWeak on an instance of itself)
            // then we may proceed but it will appear initializing and 
            // not yet initialized to the check above.
            // Instead set previouslyInitializedClass to recognize it on retry.
            // 如果类已完成+initialize，则没问题
            // 如果类仍在当前线程运行+initialize（即+initialize调用了自身实例的storeWeak）
            // 则可以继续，但会显示为正在初始化且尚未初始化
            // 设置previouslyInitializedClass以便在重试时识别
            previouslyInitializedClass = cls;

            // 跳转到重试标签
            goto retry;
        }
    }

    // Clean up old value, if any.
    // 清理旧值（如果有）
    if (haveOld) {
        // 从旧对象的弱引用表中注销当前位置的弱引用
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }

    // Assign new value, if any.
    // 赋值新值（如果有）
    if (haveNew) {
        // 在新对象的弱引用表中注册当前位置的弱引用
        newObj = (objc_object *)
            weak_register_no_lock(&newTable->weak_table, (id)newObj, location, 
                                  // 根据模板参数决定是否在对象正在释放时崩溃
                                  crashIfDeallocating ? CrashIfDeallocating : ReturnNilIfDeallocating);
        // weak_register_no_lock returns nil if weak store should be rejected
        // weak_register_no_lock如果弱引用存储应该被拒绝则返回nil

        // Set is-weakly-referenced bit in refcount table.
        // 在引用计数表中设置弱引用标志位
        if (!_objc_isTaggedPointerOrNil(newObj)) {
            // 设置对象的弱引用标志位（无锁版本）
            newObj->setWeaklyReferenced_nolock();
        }

        // Do not set *location anywhere else. That would introduce a race.
        // 不要在其他地方设置*location，那会引入竞争条件
        // 将新对象存储到位置
        *location = (id)newObj;
    }
    else {
        // No new value. The storage is not changed.
        // 没有新值，存储不变
    }
    
    // 解锁侧边表
    SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);

    // This must be called without the locks held, as it can invoke
    // arbitrary code. In particular, even if _setWeaklyReferenced
    // is not implemented, resolveInstanceMethod: may be, and may
    // call back into the weak reference machinery.
    // 这必须在没有持有锁的情况下调用，因为它可能调用任意代码
    // 特别是，即使_setWeaklyReferenced未实现，resolveInstanceMethod:可能已实现
    // 并且可能回调到弱引用机制
    // 调用_setWeaklyReferenced方法通知对象（如果已实现）
    callSetWeaklyReferenced((id)newObj);

    // 返回新对象
    return (id)newObj;
}


/** 
 * This function stores a new value into a __weak variable. It would
 * be used anywhere a __weak variable is the target of an assignment.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return \e newObj
 */
// 将新值存储到__weak变量中，用于任何__weak变量作为赋值目标的地方
id
objc_storeWeak(id *location, id newObj)
{
    // 调用storeWeak模板函数，有旧值和新值，如果对象正在释放则崩溃
    return storeWeak<DoHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * This function stores a new value into a __weak variable. 
 * If the new object is deallocating or the new object's class 
 * does not support weak references, stores nil instead.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return The value stored (either the new object or nil)
 */
// 将新值存储到__weak变量中，如果新对象正在释放或类不支持弱引用，则存储nil
id
objc_storeWeakOrNil(id *location, id newObj)
{
    // 调用storeWeak模板函数，有旧值和新值，如果对象正在释放则存储nil而不崩溃
    return storeWeak<DoHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 *
 * @param location Address of __weak ptr. 
 * @param newObj Object ptr. 
 */
// 初始化一个新的弱指针指向某个对象位置，用于初始化__weak变量
id
objc_initWeak(id *location, id newObj)
{
    // 如果新对象为nil，直接将位置设置为nil并返回
    if (!newObj) {
        *location = nil;
        return nil;
    }

    // 调用storeWeak模板函数，没有旧值，有新值，如果对象正在释放则崩溃
    return storeWeak<DontHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object*)newObj);
}

// 初始化一个新的弱指针，如果对象正在释放或类不支持弱引用，则存储nil
id
objc_initWeakOrNil(id *location, id newObj)
{
    // 如果新对象为nil，直接将位置设置为nil并返回
    if (!newObj) {
        *location = nil;
        return nil;
    }

    // 调用storeWeak模板函数，没有旧值，有新值，如果对象正在释放则存储nil而不崩溃
    return storeWeak<DontHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object*)newObj);
}


/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 * 
 * @param location The weak pointer address. 
 */
// 销毁弱指针与其引用的对象之间的关系，从内部弱引用表中移除
void
objc_destroyWeak(id *location)
{
    // 调用storeWeak模板函数，有旧值，没有新值，不崩溃
    (void)storeWeak<DoHaveOld, DontHaveNew, DontCrashIfDeallocating>
        (location, nil);
}


/*
  Once upon a time we eagerly cleared *location if we saw the object 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/

// 从弱引用位置加载对象并保留它（增加引用计数），返回保留后的对象
id
objc_loadWeakRetained(id *location)
{
    // 声明变量：对象、结果、类
    id obj;
    id result;
    Class cls;

    // 侧边表指针
    SideTable *table;
    
    // 重试标签：如果位置的值在我们操作期间改变，需要重试
 retry:
    // fixme std::atomic this load
    // 读取弱引用位置的值
    obj = *location;
    // 如果是标记指针或nil，直接返回
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    
    // 获取对象对应的侧边表
    table = &SideTables()[obj];
    
    // 锁定侧边表
    table->lock();
    // 如果位置的值已经改变（被其他线程修改），解锁并重试
    if (*location != obj) {
        table->unlock();
        goto retry;
    }

    // Check that the object we found is actually something that has weak
    // references, to check for corruption. This doesn't detect cases where an
    // unregistered weak reference points to an object that has other weak
    // references, but it will catch cases where the target object was
    // deallocated or the weak reference contains garbage.
    // 检查找到的对象是否真的有弱引用，以检查损坏
    // 查找被引用对象对应的弱引用条目
    weak_entry_t *entry = weak_entry_for_referent(&table->weak_table,
                                                  (objc_object *)obj);
    // 如果找不到条目（慢路径），说明可能有问题
    if (slowpath(entry == NULL)) {
        // Unlock before we scan the weak tables, since the scan will lock each
        // table as it scans.
        // 在扫描弱引用表之前解锁，因为扫描会锁定每个表
        table->unlock();
        // 执行弱引用表扫描
        weakTableScan();
        // 记录错误信息（立即记录并在崩溃时记录）
        _objc_fault_and_log("Weak reference loaded from %p contains %p which is not "
                            "in the weak references table", location, obj);

        // Return the object we found. It's not really weakly referenced,
        // so we don't need to use tryRetain.
        // 返回找到的对象，它不是真正的弱引用，所以不需要使用tryRetain
        return objc_retain(obj);
    }

    // 初始化结果为对象
    result = obj;

    // 获取对象的类
    cls = obj->ISA();
    // 如果类没有自定义retain/release实现（快速路径）
    if (! cls->hasCustomRR()) {
        // Fast case. We know +initialize is complete because
        // default-RR can never be set before then.
        // 快速路径：我们知道+initialize已完成，因为默认RR在此之前无法设置
        ASSERT(cls->isInitialized());
        // 尝试保留对象（根尝试保留）
        if (! obj->rootTryRetain()) {
            // 如果保留失败，结果为nil
            result = nil;
        }
    }
    else {
        // Slow case. We must check for +initialize and call it outside
        // the lock if necessary in order to avoid deadlocks.
        // Use lookUpImpOrForward so we can avoid the assert in
        // class_getInstanceMethod, since we intentionally make this
        // callout with the lock held.
        // 慢速路径：必须检查+initialize并在必要时在锁外调用以避免死锁
        // 使用lookUpImpOrForward以便避免class_getInstanceMethod中的断言
        // 因为我们有意在持有锁的情况下进行此调用
        // 如果类已初始化或当前线程正在初始化该类
        if (cls->isInitialized() || _thisThreadIsInitializingClass(cls)) {
            // 查找retainWeakReference方法的实现
            BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
                lookUpImpOrForwardTryCache(obj, @selector(retainWeakReference), cls);
            // 如果方法是消息转发，结果为nil
            if ((IMP)tryRetain == _objc_msgForward) {
                result = nil;
            }
            // 否则调用tryRetain方法，如果失败则结果为nil
            else if (! (*tryRetain)(obj, @selector(retainWeakReference))) {
                result = nil;
            }
        }
        else {
            // 类未初始化，解锁侧边表
            table->unlock();
            // 初始化类
            class_initialize(cls, obj);
            // 跳转到重试标签
            goto retry;
        }
    }
        
    // 解锁侧边表
    table->unlock();
    // 返回结果
    return result;
}

/** 
 * This loads the object referenced by a weak pointer and returns it, after
 * retaining and autoreleasing the object to ensure that it stays alive
 * long enough for the caller to use it. This function would be used
 * anywhere a __weak variable is used in an expression.
 * 
 * @param location The weak pointer address
 * 
 * @return The object pointed to by \e location, or \c nil if \e location is \c nil.
 */
// 从弱指针加载对象并返回，在保留和自动释放对象后，确保对象在调用者使用期间保持存活
id
objc_loadWeak(id *location)
{
    // 如果位置为nil，直接返回nil
    if (!*location) return nil;
    // 加载弱引用并保留，然后自动释放，确保对象在调用者使用期间存活
    return objc_autorelease(objc_loadWeakRetained(location));
}


/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id src = ...;
 *  __weak id dst = src;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the destination variable. (Concurrent weak clear is safe.)
 *
 * @param dst The destination variable.
 * @param src The source variable.
 */
// 将一个弱指针从一个位置复制到另一个位置，当目标位置还没有弱指针时使用
void
objc_copyWeak(id *dst, id *src)
{
    // 从源位置加载弱引用并保留对象
    id obj = objc_loadWeakRetained(src);
    // 在目标位置初始化弱引用
    objc_initWeak(dst, obj);
    // 释放之前保留的对象（因为initWeak会增加引用计数）
    objc_release(obj);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to either weak variable. (Concurrent weak clear is safe.)
 *
 */
// 将一个弱指针从一个位置移动到另一个位置，移动前目标必须未初始化，移动后源为nil
void
objc_moveWeak(id *dst, id *src)
{
    // 声明对象和侧边表变量
    id obj;
    SideTable *table;

    // 重试标签：如果源位置的值在我们操作期间改变，需要重试
retry:
    // 读取源位置的值
    obj = *src;
    // 如果对象为nil，将目标设置为nil并返回
    if (obj == nil) {
        *dst = nil;
        return;
    }

    // 获取对象对应的侧边表
    table = &SideTables()[obj];
    // 锁定侧边表
    table->lock();
    // 如果源位置的值已经改变（被其他线程修改），解锁并重试
    if (*src != obj) {
        table->unlock();
        goto retry;
    }

    // 从弱引用表中注销源位置的弱引用
    weak_unregister_no_lock(&table->weak_table, obj, src);
    // 在弱引用表中注册目标位置的弱引用
    weak_register_no_lock(&table->weak_table, obj, dst, DontCheckDeallocating);
    // 将对象存储到目标位置
    *dst = obj;
    // 将源位置设置为nil
    *src = nil;
    // 解锁侧边表
    table->unlock();
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_BOUNDARY which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_BOUNDARY for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
**********************************************************************/

// The TLS for ReturnAutoreleaseInfo
// 返回自动释放信息的线程本地存储：第一个字（存储返回的对象信息）
objc::ExplicitInit<tls_direct(uintptr_t, tls_key::return_autorelease_object,
           ReturnAutoreleaseInfo::TlsDealloc)>
	ReturnAutoreleaseInfo::tlsFirstWord;
// 返回自动释放信息的线程本地存储：返回地址
objc::ExplicitInit<tls_direct(const void *, tls_key::return_autorelease_address)>
	ReturnAutoreleaseInfo::tlsReturnAddress;

// 断点函数：当对象在没有自动释放池的情况下被自动释放时调用
BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));
// 断点函数：当自动释放池无效时调用
BREAKPOINT_FUNCTION(void objc_autoreleasePoolInvalid(const void *token));

// 自动释放池页类，私有继承自AutoreleasePoolPageData
class AutoreleasePoolPage : private AutoreleasePoolPageData
{
	// 声明thread_data_t为友元类
	friend struct thread_data_t;

public:
	// 定义页面大小常量
	static size_t const SIZE =
#if PROTECT_AUTORELEASEPOOL
		// 如果启用自动释放池保护，使用最大页面大小（必须是虚拟内存页面大小的倍数）
		PAGE_MAX_SIZE;  // must be multiple of vm page size
#else
		// 否则使用最小页面大小（大小和对齐，2的幂）
		PAGE_MIN_SIZE;  // size and alignment, power of 2
#endif

private:
    // EMPTY_POOL_PLACEHOLDER is stored in TLS when exactly one pool is 
    // pushed and it has never contained any objects. This saves memory 
    // when the top level (i.e. libdispatch) pushes and pops pools but 
    // never uses them.
    // 空池占位符：当恰好有一个池被推入且从未包含任何对象时存储在TLS中
    // 这节省内存，当顶层（如libdispatch）推入和弹出池但从不使用它们时
#   define EMPTY_POOL_PLACEHOLDER ((AutoreleasePoolPage*)1)

    // 定义池边界为nil
#   define POOL_BOUNDARY nil

    // 前向声明热页析构类
    class HotPageDealloc;
    // 线程本地存储的热页指针，使用显式初始化
    static objc::ExplicitInit<tls_direct(AutoreleasePoolPage *, tls_key::autorelease_pool, HotPageDealloc)>
        hotPage_;
	// 定义涂鸦字节常量，用于释放后填充内存（0xA3A3A3A3）
	static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
	// 计算页面可以存储的对象数量
	static size_t const COUNT = SIZE / sizeof(id);
    // 定义最大故障次数
    static size_t const MAX_FAULTS = 1;

    // SIZE-sizeof(*this) bytes of contents follow
    // 后面跟着SIZE-sizeof(*this)字节的内容

    // 重载new操作符，用于分配对齐的内存
    static void * operator new(size_t size) {
        // 结果指针初始化为0
        void *result = 0;
        // 使用posix_memalign分配对齐的内存，对齐到SIZE，大小为SIZE
        int r = posix_memalign(&result, SIZE, SIZE);
        // 断言分配成功
        ASSERT(r == 0);
        // 返回分配的内存
        return result;
    }
    // 重载delete操作符，用于释放内存
    static void operator delete(void * p) {
        // 释放内存
        return free(p);
    }

    // 保护页面，将页面设置为只读
    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        // 如果启用自动释放池保护，将页面内存保护设置为只读
        mprotect(this, SIZE, PROT_READ);
        // 检查页面完整性
        check();
#endif
    }

    // 取消保护页面，将页面设置为可读写
    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        // 如果启用自动释放池保护，先检查页面完整性
        check();
        // 将页面内存保护设置为可读写
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }

    // 检查自动释放池是否过大
    void checkTooMuchAutorelease()
    {
        // 计算新的深度（当前深度+1）
        int newDepth = depth+1;
        // 如果新深度达到警告阈值且故障次数未超过最大值
        if (newDepth == objc::PageCountWarning && numFaults < MAX_FAULTS) {
            // 触发故障报告
            _objc_fault("Large Autorelease Pool");
            // 增加故障计数
            numFaults++;
        }
    }

	// 构造函数：创建新的自动释放池页
	AutoreleasePoolPage(AutoreleasePoolPage *newParent) :
		// 初始化基类：开始位置、当前线程、父页面、深度、高水位标记
		AutoreleasePoolPageData(begin(),
								objc_thread_self(),
								newParent,
								newParent ? 1+newParent->depth : 0,
								newParent ? newParent->hiwat : 0)
    {
        // 如果页面计数警告已启用
        if (objc::PageCountWarning != -1) {
            // 检查自动释放池是否过大
            checkTooMuchAutorelease();
        }

        // 如果有父页面
        if (parent) {
            // 检查父页面完整性
            parent->check();
            // 断言父页面没有子页面
            ASSERT(!parent->child);
            // 取消保护父页面以便修改
            parent->unprotect();
            // 将当前页面设置为父页面的子页面
            parent->child = this;
            // 重新保护父页面
            parent->protect();
        }
        // 保护当前页面
        protect();
    }

    // 析构函数：销毁自动释放池页
    ~AutoreleasePoolPage() 
    {
        // 检查页面完整性
        check();
        // 取消保护页面
        unprotect();
        // 断言页面为空 
        ASSERT(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        // 非递归：我们不希望在线程积累大量垃圾时导致栈溢出
        // 断言没有子页面
        ASSERT(!child);
    }

    // 模板函数：报告页面损坏信息
    template<typename Fn>
    void
    busted(Fn log) const
    {
        // 创建正确的magic值用于比较
        magic_t right;
        // 使用提供的日志函数记录损坏信息，包括页面地址、magic值、线程信息
        log("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, objc_thread_self());
    }

    // 报告页面损坏并终止程序（不内联、冷路径、不返回）
    __attribute__((noinline, cold, noreturn))
    void
    busted_die() const
    {
        // 调用busted函数，使用_objc_fatal作为日志函数
        busted(_objc_fatal);
        // 标记为不可达（因为_objc_fatal会终止程序）
        __builtin_unreachable();
    }

    // 检查页面完整性（内联函数）
    inline void
    check(bool die = true) const
    {
        // 如果magic值检查失败或线程不匹配
        if (!magic.check() || thread != objc_thread_self()) {
            // 如果die为true，调用busted_die终止程序
            if (die) {
                busted_die();
            } else {
                // 否则只记录信息，不终止程序
                busted(_objc_inform);
            }
        }
    }

    // 快速检查页面完整性（内联函数，性能优化版本）
    inline void
    fastcheck() const
    {
#if CHECK_AUTORELEASEPOOL
        // 如果启用自动释放池检查，执行完整检查
        check();
#else
        // 否则只进行快速magic检查
        if (! magic.fastcheck()) {
            // 如果快速检查失败，终止程序
            busted_die();
        }
#endif
    }


    // 返回页面数据区域的开始位置
    id * begin() {
        // 返回当前对象之后的内存地址（跳过对象头部）
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    // 返回页面数据区域的结束位置
    id * end() {
        // 返回当前对象加上页面大小的地址
        return (id *) ((uint8_t *)this+SIZE);
    }

    // 检查页面是否为空
    bool empty() {
        // 如果next指针等于begin，说明页面为空
        return next == begin();
    }

    // 检查页面是否已满
    bool full() { 
        // 如果next指针等于end，说明页面已满
        return next == end();
    }

    // 检查页面是否少于一半满
    bool lessThanHalfFull() {
        // 如果已使用的空间少于总空间的一半，返回true
        return (next - begin() < (end() - begin()) / 2);
    }

    // 将对象添加到自动释放池页中，返回存储位置的指针
    id *add(id obj)
    {
        // 断言页面未满
        ASSERT(!full());
        // 取消保护页面以便写入
        unprotect();
        // 返回值指针
        id *ret;

// 如果支持自动释放池指针去重功能
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        // 如果未禁用自动释放合并功能
        if (!DisableAutoreleaseCoalescing || !DisableAutoreleaseCoalescingLRU) {
            // 如果未禁用LRU（最近最少使用）合并
            if (!DisableAutoreleaseCoalescingLRU) {
                // 如果页面非空且对象不是池边界
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    // 获取顶部条目
                    AutoreleasePoolEntry *topEntry = (AutoreleasePoolEntry *)next - 1;
                    // 检查最近4个条目，看是否有相同的对象
                    for (uintptr_t offset = 0; offset < 4; offset++) {
                        // 获取偏移位置的条目
                        AutoreleasePoolEntry *offsetEntry = topEntry - offset;
                        // 如果条目超出范围或是池边界，跳出循环
                        if (offsetEntry <= (AutoreleasePoolEntry*)begin() || *(id *)offsetEntry == POOL_BOUNDARY) {
                            break;
                        }
                        // 如果找到相同对象且计数未达最大值
                        if (offsetEntry->getPointer() == (uintptr_t)obj && offsetEntry->getCount() < AutoreleasePoolEntry::maxCount) {
                            // 如果偏移大于0，需要移动条目到顶部（LRU策略）
                            if (offset > 0) {
                                // 保存找到的条目
                                AutoreleasePoolEntry found = *offsetEntry;
                                // 将条目移动到顶部
                                memmove(offsetEntry, offsetEntry + 1, offset * sizeof(*offsetEntry));
                                // 将找到的条目放到顶部
                                *topEntry = found;
                            }
                            // 增加计数
                            topEntry->incrementCount();
                            // 设置返回值为顶部条目
                            ret = (id *)topEntry;  // need to reset ret
                            // 跳转到完成标签
                            goto done;
                        }
                    }
                }
            } else {
                // 简单模式：只检查前一个条目
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    // 获取前一个条目
                    AutoreleasePoolEntry *prevEntry = (AutoreleasePoolEntry *)next - 1;
                    // 如果前一个条目是相同对象且计数未达最大值
                    if (prevEntry->getPointer() == (uintptr_t)obj && prevEntry->getCount() < AutoreleasePoolEntry::maxCount) {
                        // 增加计数
                        prevEntry->incrementCount();
                        // 设置返回值为前一个条目
                        ret = (id *)prevEntry;  // need to reset ret
                        // 跳转到完成标签
                        goto done;
                    }
                }
            }
        }
#endif
        // 标准路径：将对象添加到next位置
        ret = next;  // faster than `return next-1` because of aliasing
        // 存储对象并递增next指针
        *next++ = obj;
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        // Make sure obj fits in the bits available for it
        // 确保对象适合可用的位数
        ASSERT(((AutoreleasePoolEntry *)ret)->getPointer() == (uintptr_t)obj);
#endif
     // 完成标签
     done:
        // 重新保护页面
        protect();
        // 返回存储位置的指针
        return ret;
    }

    // Release the conceptually autoreleased object in the ReturnAutoreleaseInfo
    // TLS, clearing the TLS before performing the release. Returns true if an
    // object was released, false if the TLS was already empty.
    // 释放ReturnAutoreleaseInfo TLS中概念上自动释放的对象，在执行释放前清除TLS
    // 如果释放了对象返回true，如果TLS已为空返回false
    static bool releaseReturnAutoreleaseTLS() {
        // 获取返回自动释放信息
        ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
        // 如果TLS中有返回的对象
        if (id obj = info.getReturnedObject()) {
            // 清除TLS信息
            setReturnAutoreleaseInfo({});
            // 释放对象
            objc_release(obj);
            // 返回true表示释放了对象
            return true;
        }
        // 返回false表示TLS为空
        return false;
    }

    // 释放页面中的所有对象
    void releaseAll() 
    {
        // 释放直到页面开始位置（即释放所有对象）
        releaseUntil(begin());
    }

    // 释放从当前位置到stop位置之间的所有对象
    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        // 非递归：我们不希望在线程积累大量垃圾时导致栈溢出

        // 循环处理，因为释放对象可能会产生新的自动释放对象
        do {
            // 当next指针不等于stop时继续释放
            while (this->next != stop) {
                // Restart from hotPage() every time, in case -release
                // autoreleased more objects
                // 每次都从hotPage重新开始，因为-release可能自动释放了更多对象
                // 获取当前热页
                AutoreleasePoolPage *page = hotPage();

                // fixme I think this `while` can be `if`, but I can't prove it
                // 如果页面为空，向上查找父页面直到找到非空页面
                while (page->empty()) {
                    // 移动到父页面
                    page = page->parent;
                    // 设置新的热页
                    setHotPage(page);
                }

                // 取消保护页面以便修改
                page->unprotect();
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                // 获取顶部条目并递减next指针
                AutoreleasePoolEntry* entry = (AutoreleasePoolEntry*) --page->next;

                // create an obj with the zeroed out top byte and release that
                // 从条目中获取对象指针（清除顶部字节）
                id obj = (id)entry->getPointer();
                // 获取计数（在memset之前获取）
                int count = (int)entry->getCount();  // grab these before memset
#else
                // 标准路径：直接获取对象并递减next指针
                id obj = *--page->next;
#endif
                // 用涂鸦字节填充已释放的位置（用于检测内存错误）
                memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
                // 重新保护页面
                page->protect();

                // 如果对象不是池边界
                if (obj != POOL_BOUNDARY) {
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                    // release count+1 times since it is count of the additional
                    // autoreleases beyond the first one
                    // 释放count+1次，因为count是除第一次之外的额外自动释放次数
                    for (int i = 0; i < count + 1; i++) {
                        // 释放对象
                        objc_release(obj);
                    }
#else
                    // 标准路径：只释放一次
                    objc_release(obj);
#endif
                }
            }

            // Stale return autorelease info is conceptually autoreleased. If
            // there is any, release the object in the info. If stale info is
            // present, we have to loop in case it autoreleased more objects
            // when it was released.
            // 过期的返回自动释放信息在概念上是自动释放的
            // 如果有，释放信息中的对象
            // 如果存在过期信息，必须循环，因为释放时可能自动释放了更多对象
        } while (releaseReturnAutoreleaseTLS());

        // 设置当前页面为热页
        setHotPage(this);

#if DEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            ASSERT(page->empty());
        }
#endif
    }

    // 销毁页面及其所有子页面（非递归实现）
    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        // 非递归：我们不希望在线程积累大量垃圾时导致栈溢出
        // 从当前页面开始
        AutoreleasePoolPage *page = this;
        // 找到最深的子页面
        while (page->child) page = page->child;

        // 从最深的子页面开始向上删除
        AutoreleasePoolPage *deathptr;
        do {
            // 保存要删除的页面
            deathptr = page;
            // 移动到父页面
            page = page->parent;
            // 如果有父页面
            if (page) {
                // 取消保护父页面
                page->unprotect();
                // 清除父页面的子页面指针
                page->child = nil;
                // 重新保护父页面
                page->protect();
            }
            // 取消保护要删除的页面
            deathptr->unprotect();
            // 删除页面
            delete deathptr;
        } while (deathptr != this);  // 直到删除到当前页面
    }

    // 根据指针查找对应的页面（const void*版本）
    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        // 转换为uintptr_t并调用重载版本
        return pageForPointer((uintptr_t)p);
    }

    // 根据指针查找对应的页面（uintptr_t版本）
    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        // 结果页面指针
        AutoreleasePoolPage *result;
        // 计算指针在页面内的偏移量
        uintptr_t offset = p % SIZE;

        // 断言偏移量至少等于页面头部大小
        ASSERT(offset >= sizeof(AutoreleasePoolPage));

        // 计算页面起始地址（指针减去偏移量）
        result = (AutoreleasePoolPage *)(p - offset);
        // 快速检查页面完整性
        result->fastcheck();

        // 返回页面指针
        return result;
    }


    // 检查是否有空池占位符
    static inline bool haveEmptyPoolPlaceholder()
    {
        // 如果热页是空池占位符，返回true
        return hotPage_.get() == EMPTY_POOL_PLACEHOLDER;
    }

    // 设置空池占位符
    static inline id* setEmptyPoolPlaceholder()
    {
        // 将热页设置为空池占位符
        hotPage_.get() = EMPTY_POOL_PLACEHOLDER;
        // 返回占位符的id*指针
        return (id *)EMPTY_POOL_PLACEHOLDER;
    }

    // 获取当前热页（正在使用的页面）
    static inline AutoreleasePoolPage *hotPage() 
    {
        // 从TLS获取热页
        AutoreleasePoolPage *result = hotPage_.get();
        // 如果是空池占位符，返回nil
        if (result == EMPTY_POOL_PLACEHOLDER) return nil;
        // 如果结果不为空，快速检查页面完整性
        if (result) result->fastcheck();
        // 返回热页
        return result;
    }

    // 设置当前热页
    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        // 如果页面不为空，快速检查页面完整性
        if (page) page->fastcheck();
        // 将页面设置为热页
        hotPage_.get() = page;
    }

    // 获取冷页（最顶层的页面，最早创建的页面）
    static inline AutoreleasePoolPage *coldPage() 
    {
        // 从热页开始
        AutoreleasePoolPage *result = hotPage();
        // 如果有结果
        if (result) {
            // 向上遍历到最顶层的父页面
            while (result->parent) {
                // 移动到父页面
                result = result->parent;
                // 快速检查页面完整性
                result->fastcheck();
            }
        }
        // 返回冷页
        return result;
    }


    // 快速路径：将对象添加到自动释放池
    static inline id *autoreleaseFast(id obj)
    {
        // 获取当前热页
        AutoreleasePoolPage *page = hotPage();
        // 如果页面存在且未满，直接添加到页面
        if (page && !page->full()) {
            return page->add(obj);
        } else if (page) {
            // 如果页面已满，调用满页处理函数
            return autoreleaseFullPage(obj, page);
        } else {
            // 如果没有页面，调用无页处理函数
            return autoreleaseNoPage(obj);
        }
    }

    // 处理满页的情况（不内联，性能优化）
    static __attribute__((noinline))
    id *autoreleaseFullPage(id obj, AutoreleasePoolPage *page)
    {
        // The hot page is full. 
        // Step to the next non-full page, adding a new page if necessary.
        // Then add the object to that page.
        // 热页已满
        // 移动到下一个未满的页面，必要时添加新页面
        // 然后将对象添加到该页面
        // 断言页面是热页
        ASSERT(page == hotPage());
        // 断言页面已满或启用了调试池分配
        ASSERT(page->full()  ||  DebugPoolAllocation);

        // 循环直到找到未满的页面
        do {
            // 如果有子页面，移动到子页面
            if (page->child) page = page->child;
            // 否则创建新的子页面
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        // 设置新的热页
        setHotPage(page);

        // dtrace probe
        // dtrace探针：记录自动释放池增长
        OBJC_RUNTIME_AUTORELEASE_POOL_GROW(page->depth);

        // 将对象添加到页面
        return page->add(obj);
    }

    // 处理没有页面的情况（不内联，性能优化）
    static __attribute__((noinline))
    id *autoreleaseNoPage(id obj)
    {
        // "No page" could mean no pool has been pushed
        // or an empty placeholder pool has been pushed and has no contents yet
        // "无页面"可能意味着没有池被推入
        // 或者已推入空占位符池但还没有内容
        // 断言没有热页
        ASSERT(!hotPage());

        // 是否需要推送额外的边界
        bool pushExtraBoundary = false;
        // 如果有空池占位符
        if (haveEmptyPoolPlaceholder()) {
            // We are pushing a second pool over the empty placeholder pool
            // or pushing the first object into the empty placeholder pool.
            // Before doing that, push a pool boundary on behalf of the pool 
            // that is currently represented by the empty placeholder.
            // 我们在空占位符池上推入第二个池
            // 或者将第一个对象推入空占位符池
            // 在此之前，为当前由空占位符表示的池推送一个池边界
            pushExtraBoundary = true;
        }
        // 如果对象不是池边界且启用了缺失池调试
        else if (obj != POOL_BOUNDARY  &&  DebugMissingPools) {
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            // 我们在没有池的情况下推入对象
            // 并且环境变量请求了无池调试
            // 记录警告信息
            _objc_inform("MISSING POOLS: (%p) Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         objc_thread_self(), (void*)obj, object_getClassName(obj));
            // 调用断点函数
            objc_autoreleaseNoPool(obj);

            // 如果缺失池是致命错误
            if (DebugMissingPools == Fatal)
                _objc_fatal("Missing pools are a fatal error");

            // 返回nil
            return nil;
        }
        // 如果对象是池边界且未启用每池分配调试
        else if (obj == POOL_BOUNDARY  &&  !DebugPoolAllocation) {
            // We are pushing a pool with no pool in place,
            // and alloc-per-pool debugging was not requested.
            // Install and return the empty pool placeholder.
            // 我们在没有池的情况下推入池
            // 并且未请求每池分配调试
            // 安装并返回空池占位符
            return setEmptyPoolPlaceholder();
        }

        // We are pushing an object or a non-placeholder'd pool.
        // 我们正在推入对象或非占位符池

        // Install the first page.
        // 安装第一页
        // 创建新的页面（没有父页面）
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        // 设置为热页
        setHotPage(page);

        // dtrace probe
        // dtrace探针：记录自动释放池增长
        OBJC_RUNTIME_AUTORELEASE_POOL_GROW(page->depth);

        // Push a boundary on behalf of the previously-placeholder'd pool.
        // 为之前占位符的池推送边界
        if (pushExtraBoundary) {
            // 添加池边界
            page->add(POOL_BOUNDARY);
        }

        // Push the requested object or pool.
        // 推送请求的对象或池
        // 将对象添加到页面
        return page->add(obj);
    }


    // 在新页面上自动释放对象（不内联，性能优化）
    static __attribute__((noinline))
    id *autoreleaseNewPage(id obj)
    {
        // 获取当前热页
        AutoreleasePoolPage *page = hotPage();
        // 如果有页面，调用满页处理函数
        if (page) return autoreleaseFullPage(obj, page);
        // 否则调用无页处理函数
        else return autoreleaseNoPage(obj);
    }

public:
    // 初始化线程本地存储
    static void initTLS(void) {
        // 初始化热页TLS
        hotPage_.init();
    }

    // 将对象添加到自动释放池（内联函数，性能关键路径）
    static inline id autorelease(id obj)
    {
        // 断言对象不是标记指针或nil
        ASSERT(!_objc_isTaggedPointerOrNil(obj));
        // 快速路径：将对象添加到自动释放池
        id *dest __unused = autoreleaseFast(obj);
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        // 断言：dest为空、是空池占位符、或指向的对象匹配
        ASSERT(!dest  ||  dest == (id *)EMPTY_POOL_PLACEHOLDER  ||  (id)((AutoreleasePoolEntry *)dest)->getPointer() == obj);
#else
        // 断言：dest为空、是空池占位符、或存储的对象匹配
        ASSERT(!dest  ||  dest == (id *)EMPTY_POOL_PLACEHOLDER  ||  *dest == obj);
#endif
        // 返回对象
        return obj;
    }

    // 将TLS中的自动释放对象移动到池中（内联函数）
    static inline void moveTLSAutoreleaseToPool(ReturnAutoreleaseInfo info)
    {
        // 如果TLS中有返回的对象
        if (id obj = info.getReturnedObject()) {
            // 如果对象来自根自动释放
            if (info.cameFromRootAutorelease) {
                // This object already got an autorelease message, don't send
                // another one.
                // 此对象已经收到autorelease消息，不要再发送一次
                // 直接添加到自动释放池
                autorelease(obj);
            } else {
                // Force this to be a real, non-elided autorelease. If this
                // calls back to the default implementation, we want it to go
                // into the pool, not the TLS.
                // 强制这是一个真正的、非省略的自动释放
                // 如果这回调到默认实现，我们希望它进入池，而不是TLS
                // 设置返回自动释放信息为阻塞状态
                setReturnAutoreleaseInfo(ReturnAutoreleaseInfo::blockedInfo());
                // 调用objc_autorelease（会进入池而不是TLS）
                objc_autorelease(obj);
            }
        }
        // 清除返回自动释放信息
        setReturnAutoreleaseInfo({});
    }

    // 推入新的自动释放池（内联函数，性能关键路径）
    static inline void *push() 
    {
        // 获取当前返回自动释放信息
        ReturnAutoreleaseInfo info = getReturnAutoreleaseInfo();
        // 将TLS中的自动释放对象移动到池中
        moveTLSAutoreleaseToPool(info);

        // 目标位置指针
        id *dest;
        // 如果启用了调试池分配（慢路径）
        if (slowpath(DebugPoolAllocation)) {
            // Each autorelease pool starts on a new pool page.
            // 每个自动释放池在新池页面上开始
            // 在新页面上添加池边界
            dest = autoreleaseNewPage(POOL_BOUNDARY);
        } else {
            // 快速路径：在现有页面上添加池边界
            dest = autoreleaseFast(POOL_BOUNDARY);
        }
        // 断言：dest是空池占位符或存储的是池边界
        ASSERT(dest == (id *)EMPTY_POOL_PLACEHOLDER || *dest == POOL_BOUNDARY);

        // dtrace probe
        // dtrace探针：记录自动释放池推入
        OBJC_RUNTIME_AUTORELEASE_POOL_PUSH(dest);

        // 返回池标记（用于后续pop）
        return dest;
    }

    // 处理无效的pop操作（不内联、冷路径）
    __attribute__((noinline, cold))
    static void badPop(void *token)
    {
        // 静态变量：是否已经抱怨过
        static bool complained = false;
        // 判断是否会终止程序（调试池分配为致命错误或SDK版本足够新）
        bool willTerminate = (DebugPoolAllocation == Fatal
                              || sdkIsAtLeast(10_12, 10_0, 10_0, 3_0, 2_0));

        // 如果还没有抱怨过
        if (!complained) {
            // 标记为已抱怨
            complained = true;
            // 记录错误信息（立即记录并在崩溃时记录）
            _objc_inform_now_and_on_crash
                ("Invalid or prematurely-freed autorelease pool %p. "
                 "Set a breakpoint on objc_autoreleasePoolInvalid to debug. ",
                 token);
            // 如果不会终止，记录继续执行的信息
            if (!willTerminate)
                _objc_inform("Proceeding anyway.  Memory errors are likely.");
        }
        // 调用断点函数
        objc_autoreleasePoolInvalid(token);

        // 如果会终止，调用致命错误函数
        if (willTerminate)
            _objc_fatal("Invalid autorelease pools are a fatal error");
    }

    // 模板函数：弹出页面（根据allowDebug参数决定是否启用调试功能）
    template<bool allowDebug>
    static void
    popPage(void *token, AutoreleasePoolPage *page, id *stop)
    {
        // 如果允许调试且启用了打印高水位标记
        if (allowDebug && PrintPoolHiwat) printHiwat();

        // 释放从当前位置到stop位置之间的所有对象
        page->releaseUntil(stop);

        // memory: delete empty children
        // 内存：删除空的子页面
        // 如果允许调试且启用了调试池分配且页面为空
        if (allowDebug && DebugPoolAllocation  &&  page->empty()) {
            // special case: delete everything during page-per-pool debugging
            // 特殊情况：在每池调试期间删除所有内容
            // 保存父页面
            AutoreleasePoolPage *parent = page->parent;
            // 删除页面及其所有子页面
            page->kill();
            // 设置父页面为热页
            setHotPage(parent);
        } 
        // 如果允许调试且启用了调试缺失池且页面为空且没有父页面
        else if (allowDebug && DebugMissingPools  &&  page->empty()  &&  !page->parent) {
            // special case: delete everything for pop(top)
            // when debugging missing autorelease pools
            // 特殊情况：在调试缺失自动释放池时，为pop(top)删除所有内容
            // 删除页面及其所有子页面
            page->kill();
            // 设置热页为nil
            setHotPage(nil);
        } 
        // 如果页面有子页面
        else if (page->child) {
            // hysteresis: keep one empty child if page is more than half full
            // 滞后：如果页面超过一半满，保留一个空子页面
            // 如果页面少于一半满
            if (page->lessThanHalfFull()) {
                // 删除子页面
                page->child->kill();
            }
            // 如果子页面有子页面
            else if (page->child->child) {
                // 删除子页面的子页面
                page->child->child->kill();
            }
        }
    }

    // 调试版本的popPage（不内联、冷路径）
    __attribute__((noinline, cold))
    static void
    popPageDebug(void *token, AutoreleasePoolPage *page, id *stop)
    {
        // 调用popPage模板函数，启用调试功能
        popPage<true>(token, page, stop);
    }

    // 弹出自动释放池（内联函数，性能关键路径）
    static inline void
    pop(void *token)
    {
        // dtrace probe
        // dtrace探针：记录自动释放池弹出
        OBJC_RUNTIME_AUTORELEASE_POOL_POP(token);

        // We may have an object in the ReturnAutorelease TLS when the pool is
        // otherwise empty. Release that first before checking for an empty pool
        // so we don't return prematurely. Loop in case the release placed a new
        // object in the TLS.
        // 当池为空时，我们可能在ReturnAutorelease TLS中有一个对象
        // 在检查空池之前先释放它，这样我们就不会过早返回
        // 循环以防释放将新对象放入TLS
        // 循环释放TLS中的返回自动释放对象
        while (releaseReturnAutoreleaseTLS())
            ;

        // 页面指针和停止位置指针
        AutoreleasePoolPage *page;
        id *stop;
        // 如果token是空池占位符
        if (token == (void*)EMPTY_POOL_PLACEHOLDER) {
            // Popping the top-level placeholder pool.
            // 弹出顶层占位符池
            // 获取热页
            page = hotPage();
            // 如果没有页面
            if (!page) {
                // Pool was never used. Clear the placeholder.
                // 池从未使用过，清除占位符
                return setHotPage(nil);
            }
            // Pool was used. Pop its contents normally.
            // Pool pages remain allocated for re-use as usual.
            // 池已使用，正常弹出其内容
            // 池页面保持分配以供重用
            // 获取冷页
            page = coldPage();
            // 将token设置为冷页的开始位置
            token = page->begin();
        } else {
            // 根据token查找对应的页面
            page = pageForPointer(token);
        }

        // 将token转换为停止位置指针
        stop = (id *)token;
        // 如果停止位置不是池边界
        if (*stop != POOL_BOUNDARY) {
            // 如果停止位置是页面开始且没有父页面
            if (stop == page->begin()  &&  !page->parent) {
                // Start of coldest page may correctly not be POOL_BOUNDARY:
                // 1. top-level pool is popped, leaving the cold page in place
                // 2. an object is autoreleased with no pool
                // 最冷页的开始可能正确不是POOL_BOUNDARY：
                // 1. 弹出顶层池，留下冷页
                // 2. 在没有池的情况下自动释放对象
            } else {
                // Error. For bincompat purposes this is not 
                // fatal in executables built with old SDKs.
                // 错误。为了二进制兼容性，这在用旧SDK构建的可执行文件中不是致命的
                // 调用badPop处理错误
                return badPop(token);
            }
        }

        // 如果启用了调试功能（慢路径）
        if (slowpath(PrintPoolHiwat || DebugPoolAllocation || DebugMissingPools)) {
            // 调用调试版本的popPage
            return popPageDebug(token, page, stop);
        }

        // 调用正常版本的popPage（不启用调试）
        return popPage<false>(token, page, stop);
    }

    // 打印页面内容（不内联、冷路径，用于调试）
    __attribute__((noinline, cold))
    void print()
    {
        // 打印页面信息：地址、是否满、是否热页、是否冷页
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        // 检查页面完整性（不终止程序）
        check(false);
        // 遍历页面中的所有条目
        for (id *p = begin(); p < next; p++) {
            // 如果是池边界
            if (*p == POOL_BOUNDARY) {
                // 打印池边界信息
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                // 获取条目
                AutoreleasePoolEntry *entry = (AutoreleasePoolEntry *)p;
                // 如果计数大于0（有去重）
                if (entry->getCount() > 0) {
                    // 获取对象指针
                    id obj = (id)entry->getPointer();
                    // 打印对象信息，包括自动释放计数
                    _objc_inform("[%p]  %#16lx  %s  autorelease count %lu",
                                 p, (unsigned long)obj, object_getClassName(obj),
                                 (unsigned long)entry->getCount() + 1);
                    // 跳转到完成标签
                    goto done;
                }
#endif
                // 标准路径：打印对象信息
                _objc_inform("[%p]  %#16lx  %s",
                             p, (unsigned long)*p, object_getClassName(*p));
             // 完成标签
             done:;
            }
        }
    }

    // 打印所有自动释放池（不内联、冷路径，用于调试）
    __attribute__((noinline, cold))
    static void printAll()
    {
        // 打印分隔线
        _objc_inform("##############");
        // 打印线程信息
        _objc_inform("AUTORELEASE POOLS for thread %p", objc_thread_self());

        // 页面指针和对象计数
        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        // 遍历所有页面，计算待释放对象总数
        for (page = coldPage(); page; page = page->child) {
            // 累加每个页面的对象数量
            objects += page->next - page->begin();
        }
        // 打印待释放对象总数
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        // 如果有空池占位符
        if (haveEmptyPoolPlaceholder()) {
            // 打印占位符页面信息
            _objc_inform("[%p]  ................  PAGE (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
            // 打印占位符池信息
            _objc_inform("[%p]  ################  POOL (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
        }
        else {
            // 遍历所有页面并打印
            for (page = coldPage(); page; page = page->child) {
                // 打印每个页面的内容
                page->print();
            }
        }

        // 打印结束分隔线
        _objc_inform("##############");
    }

// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
    // 计算额外释放的总数（不内联、冷路径）
    __attribute__((noinline, cold))
    unsigned sumOfExtraReleases()
    {
        // 初始化总和为0
        unsigned sumOfExtraReleases = 0;
        // 遍历页面中的所有条目
        for (id *p = begin(); p < next; p++) {
            // 如果不是池边界
            if (*p != POOL_BOUNDARY) {
                // 累加条目的计数（额外释放次数）
                sumOfExtraReleases += ((AutoreleasePoolEntry *)p)->getCount();
            }
        }
        // 返回总和
        return sumOfExtraReleases;
    }
#endif

    // 打印高水位标记（不内联、冷路径，用于调试）
    __attribute__((noinline, cold))
    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        // 检查并传播高水位标记
        // 忽略低于256的高水位标记以抑制噪音
        // 获取热页
        AutoreleasePoolPage *p = hotPage();
        // 计算当前标记（深度*每页对象数 + 当前页已用对象数）
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        // 如果标记超过当前高水位标记+256
        if (mark > p->hiwat + 256) {
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            // 初始化额外释放总和
            unsigned sumOfExtraReleases = 0;
#endif
            // 向上遍历所有父页面，更新高水位标记
            for( ; p; p = p->parent) {
                // 取消保护页面
                p->unprotect();
                // 更新高水位标记
                p->hiwat = mark;
                // 重新保护页面
                p->protect();
                
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                // 累加额外释放次数
                sumOfExtraReleases += p->sumOfExtraReleases();
#endif
            }

            // 打印高水位标记信息
            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending releases for thread %p:",
                         mark, objc_thread_self());
// 如果支持自动释放池指针去重
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            // 如果有额外释放
            if (sumOfExtraReleases > 0) {
                // 打印额外自动释放信息
                _objc_inform("POOL HIGHWATER: extra sequential autoreleases of objects: %u",
                             sumOfExtraReleases);
            }
#endif

            // 打印堆栈跟踪
            _objc_inform_backtrace("POOL HIGHWATER:     ");
        }
    }

#undef POOL_BOUNDARY

    friend struct ReturnAutoreleaseInfo::TlsDealloc;
};

// ReturnAutoreleaseInfo TLS析构函数：当TLS被销毁时调用
void ReturnAutoreleaseInfo::TlsDealloc::operator()(uintptr_t firstWord) {
    // Release the object in the TLS. Loop in case it autoreleases something
    // else into the TLS. Once that loop completes, there may be more objects
    // in the actual autorelease pool. These will be taken care of by
    // tls_dealloc.
    // 释放TLS中的对象。循环以防它自动释放其他对象到TLS中
    // 一旦循环完成，实际自动释放池中可能有更多对象
    // 这些将由tls_dealloc处理

    // Launder the pointer through ReturnAutoreleaseInfo to handle any
    // encoding it does.
    // 通过ReturnAutoreleaseInfo清洗指针以处理任何编码
    // 创建ReturnAutoreleaseInfo对象
    ReturnAutoreleaseInfo info;
    // 设置第一个字
    info.firstWord = firstWord;
    // 释放返回的对象
    objc_release(info.getReturnedObject());

    // Clean up any additional objects that may have been put in.
    // 清理可能已放入的任何其他对象
    // 循环释放TLS中的返回自动释放对象
    while (AutoreleasePoolPage::releaseReturnAutoreleaseTLS())
        ;
}

// 热页析构类：当热页TLS被销毁时调用
class AutoreleasePoolPage::HotPageDealloc {
public:
    // 析构函数操作符
    void operator()(AutoreleasePoolPage *p) {
        // We may have an object in the ReturnAutorelease TLS when the pool is
        // otherwise empty. Release that first before checking for an empty pool
        // so we don't return prematurely. Loop in case the release placed a new
        // object in the TLS.
        // 当池为空时，我们可能在ReturnAutorelease TLS中有一个对象
        // 在检查空池之前先释放它，这样我们就不会过早返回
        // 循环以防释放将新对象放入TLS
        // 循环释放TLS中的返回自动释放对象
        while (releaseReturnAutoreleaseTLS())
            ;

        // 如果是空池占位符
        if (p == EMPTY_POOL_PLACEHOLDER) {
            // No objects or pool pages to clean up here.
            // 这里没有对象或池页面需要清理
            return;
        }

        // reinstate TLS value while we work
        // 在我们工作时恢复TLS值
        // 设置热页为p
        setHotPage((AutoreleasePoolPage *)p);

        // 如果存在冷页
        if (AutoreleasePoolPage *page = coldPage()) {
            // 如果页面非空，弹出所有池
            if (!page->empty()) objc_autoreleasePoolPop(page->begin());  // pop all of the pools
            // 如果启用了调试功能（慢路径）
            if (slowpath(DebugMissingPools || DebugPoolAllocation)) {
                // pop() killed the pages already
                // pop()已经删除了页面
            } else {
                // 否则删除所有页面
                page->kill();  // free all of the pages
            }
        }

        // clear TLS value so TLS destruction doesn't loop
        // 清除TLS值，以便TLS销毁不会循环
        // 将热页设置为nil
        setHotPage(nil);
    }
};

objc::ExplicitInit<tls_direct(AutoreleasePoolPage *, tls_key::autorelease_pool,
                              AutoreleasePoolPage::HotPageDealloc)> AutoreleasePoolPage::hotPage_;

/***********************************************************************
* Slow paths for inline control
**********************************************************************/

// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA

// 根保留溢出处理（永不内联，慢路径）
NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    // 调用根保留函数，使用完整变体
    return rootRetain(tryRetain, RRVariant::Full);
}


// 根释放下溢处理（永不内联，慢路径）
NEVER_INLINE uintptr_t
objc_object::rootRelease_underflow(bool performDealloc)
{
    // 调用根释放函数，使用完整变体
    return rootRelease(performDealloc, RRVariant::Full);
}


// Slow path of clearDeallocating() 
// for objects with nonpointer isa
// that were ever weakly referenced 
// or whose retain count ever overflowed to the side table.
// clearDeallocating()的慢路径
// 用于具有非指针isa的对象
// 这些对象曾经被弱引用或引用计数曾经溢出到侧边表
// 清除正在释放状态（永不内联，慢路径）
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    // 断言：isa是非指针且（被弱引用或引用计数在侧边表中）
    ASSERT(isa().nonpointer  &&  (isa().weakly_referenced
#if ISA_HAS_INLINE_RC
                                  || isa().has_sidetable_rc
#endif
                                  ));

    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 锁定侧边表
    table.lock();
    // 如果对象被弱引用
    if (isa().weakly_referenced) {
        // 清除弱引用表中的条目（无锁版本，因为已经持有锁）
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
// 如果isa有内联引用计数
#if ISA_HAS_INLINE_RC
    // 如果引用计数在侧边表中
    if (isa().has_sidetable_rc) {
#endif
        // 从侧边表中删除引用计数条目
        table.refcnts.erase(this);
#if ISA_HAS_INLINE_RC
    }
#endif
    // 解锁侧边表
    table.unlock();
}

#endif

// 将TLS中的自动释放对象移动到池中（全局函数）
void moveTLSAutoreleaseToPool(ReturnAutoreleaseInfo info) {
    // 调用AutoreleasePoolPage的静态方法
    AutoreleasePoolPage::moveTLSAutoreleaseToPool(info);
}

// 根自动释放函数2（不内联、已使用，用于慢路径）
__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    // 断言对象不是标记指针
    ASSERT(!isTaggedPointer());
    // 调用AutoreleasePoolPage的autorelease方法
    return AutoreleasePoolPage::autorelease((id)this);
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


// 如果启用调试模式
#if DEBUG
// Used to assert that an object is not present in the side table.
// 用于断言对象不在侧边表中
bool
objc_object::sidetable_present() const
{
    // 初始化结果为false
    bool result = false;
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 锁定侧边表
    table.lock();

    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果找到，设置结果为true
    if (it != table.refcnts.end()) result = true;

    // 如果对象在弱引用表中注册，设置结果为true
    if (weak_is_registered_no_lock(&table.weak_table, (id)this)) result = true;

    // 解锁侧边表
    table.unlock();

    // 返回结果
    return result;
}
#endif

// 执行对象的dealloc方法
void
objc_object::performDealloc()
{
    // 如果类有自定义的dealloc启动方法
    if (ISA()->hasCustomDeallocInitiation())
        // 调用_objc_initiateDealloc方法
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(_objc_initiateDealloc));
    else
        // 否则调用标准的dealloc方法
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(dealloc));
}


// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA

// 锁定对象的侧边表
void 
objc_object::sidetable_lock() const
{
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 锁定侧边表
    table.lock();
}

// 解锁对象的侧边表
void 
objc_object::sidetable_unlock() const
{
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 解锁侧边表
    table.unlock();
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
// 将整个引用计数移动到侧边表，以及isDeallocating和weaklyReferenced标志
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, 
                                          bool isDeallocating, 
                                          bool weaklyReferenced)
{
    // 断言isa不是非指针（应该已经改为原始指针）
    ASSERT(!isa().nonpointer);        // should already be changed to raw pointer
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 获取引用计数存储的引用
    size_t& refcntStorage = table.refcnts[this];
    // 保存旧的引用计数
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that was in the isa
    // 不在释放中 - 那在isa中
    // 断言旧引用计数没有释放标志
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    // 断言旧引用计数没有弱引用标志
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    // 进位标志
    uintptr_t carry;
    // 计算新的引用计数（带进位加法）
    size_t refcnt = addc(oldRefcnt, (extra_rc - 1) << SIDE_TABLE_RC_SHIFT, 0, &carry);
    // 如果有进位，设置为固定状态
    if (carry) refcnt = SIDE_TABLE_RC_PINNED;
    // 如果正在释放，设置释放标志
    if (isDeallocating) refcnt |= SIDE_TABLE_DEALLOCATING;
    // 如果被弱引用，设置弱引用标志
    if (weaklyReferenced) refcnt |= SIDE_TABLE_WEAKLY_REFERENCED;

    // 更新引用计数存储
    refcntStorage = refcnt;
}


// Move some retain counts to the side table from the isa field.
// Returns true if the object is now pinned.
// 将一些引用计数从isa字段移动到侧边表
// 如果对象现在被固定，返回true
bool 
objc_object::sidetable_addExtraRC_nolock(size_t delta_rc)
{
    // 断言isa是非指针
    ASSERT(isa().nonpointer);
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 获取引用计数存储的引用
    size_t& refcntStorage = table.refcnts[this];
    // 保存旧的引用计数
    size_t oldRefcnt = refcntStorage;
    // isa-side bits should not be set here
    // isa侧标志位不应在此设置
    // 断言旧引用计数没有释放标志
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    // 断言旧引用计数没有弱引用标志
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    // 如果引用计数已被固定，返回true
    if (oldRefcnt & SIDE_TABLE_RC_PINNED) return true;

    // 进位标志
    uintptr_t carry;
    // 计算新的引用计数（带进位加法）
    size_t newRefcnt = 
        addc(oldRefcnt, delta_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    // 如果有进位
    if (carry) {
        // 设置引用计数为固定状态，保留旧标志位
        refcntStorage =
            SIDE_TABLE_RC_PINNED | (oldRefcnt & SIDE_TABLE_FLAG_MASK);
        // 返回true表示对象被固定
        return true;
    }
    else {
        // 否则更新引用计数
        refcntStorage = newRefcnt;
        // 返回false表示对象未被固定
        return false;
    }
}


// Move some retain counts from the side table to the isa field.
// Returns the actual count subtracted, which may be less than the request.
// 从侧边表移动一些引用计数到isa字段
// 返回实际减去的计数，可能少于请求的数量
objc_object::SidetableBorrow
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    // 断言isa是非指针
    ASSERT(isa().nonpointer);
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果未找到或引用计数为0
    if (it == table.refcnts.end()  ||  it->second == 0) {
        // Side table retain count is zero. Can't borrow.
        // 侧边表引用计数为零，无法借用
        // 返回0借用和0剩余
        return { 0, 0 };
    }
    // 保存旧的引用计数
    size_t oldRefcnt = it->second;

    // isa-side bits should not be set here
    // isa侧标志位不应在此设置
    // 断言旧引用计数没有释放标志
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    // 断言旧引用计数没有弱引用标志
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    // 计算新的引用计数（减去请求的数量）
    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT);
    // 断言不会下溢
    ASSERT(oldRefcnt > newRefcnt);  // shouldn't underflow
    // 更新引用计数
    it->second = newRefcnt;
    // 返回借用的数量和剩余的引用计数
    return { delta_rc, newRefcnt >> SIDE_TABLE_RC_SHIFT };
}


// 获取侧边表中的额外引用计数（无锁版本）
size_t 
objc_object::sidetable_getExtraRC_nolock() const
{
    // 断言isa是非指针
    ASSERT(isa().nonpointer);
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果未找到，返回0
    if (it == table.refcnts.end()) return 0;
    // 否则返回引用计数值（右移去除标志位）
    else return it->second >> SIDE_TABLE_RC_SHIFT;
}


// 清除侧边表中的额外引用计数（无锁版本）
void
objc_object::sidetable_clearExtraRC_nolock()
{
    // 断言isa是非指针
    ASSERT(isa().nonpointer);
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 从映射中删除条目
    table.refcnts.erase(it);
}


// SUPPORT_NONPOINTER_ISA
#endif


// 在侧边表中保留对象（增加引用计数）
id
objc_object::sidetable_retain(bool locked)
{
// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA
    // 断言isa不是非指针
    ASSERT(!isa().nonpointer);
#endif
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    
    // 如果未锁定，锁定侧边表
    if (!locked) table.lock();
    // 获取引用计数存储的引用
    size_t& refcntStorage = table.refcnts[this];
    // 如果引用计数未被固定
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
        // 增加引用计数
        refcntStorage += SIDE_TABLE_RC_ONE;
    }
    // 解锁侧边表
    table.unlock();

    // 返回对象自身
    return (id)this;
}


// 尝试在侧边表中保留对象（增加引用计数，如果对象正在释放则失败）
bool
objc_object::sidetable_tryRetain()
{
// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA
    // 断言isa不是非指针
    ASSERT(!isa().nonpointer);
#endif
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.
    // 这里没有自旋锁
    // _objc_rootTryRetain()仅由_objc_loadWeak()调用
    // 它已经为我们获取了锁

    // fixme can't do this efficiently with os_lock_handoff_s
    // fixme 无法使用os_lock_handoff_s高效地执行此操作
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    // 初始化结果为true
    bool result = true;
    // 尝试插入或获取引用计数条目
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_RC_ONE);
    // 获取引用计数的引用
    auto &refcnt = it.first->second;
    // 如果是新插入的条目
    if (it.second) {
        // there was no entry
        // 没有条目（已创建新条目，引用计数为1）
    } 
    // 如果引用计数有释放标志
    else if (refcnt & SIDE_TABLE_DEALLOCATING) {
        // 保留失败
        result = false;
    } 
    // 如果引用计数未被固定
    else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        // 增加引用计数
        refcnt += SIDE_TABLE_RC_ONE;
    }
    
    // 返回结果
    return result;
}


// 获取侧边表中的引用计数
uintptr_t
objc_object::sidetable_retainCount() const
{
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 初始化引用计数结果为1（基础计数）
    size_t refcnt_result = 1;
    
    // 锁定侧边表
    table.lock();
    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果找到条目
    if (it != table.refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        // 这对SIDE_TABLE_RC_PINNED也有效
        // 累加侧边表中的引用计数
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT;
    }
    // 解锁侧边表
    table.unlock();
    // 返回引用计数结果
    return refcnt_result;
}


// 检查对象是否正在释放（侧边表版本）
bool 
objc_object::sidetable_isDeallocating() const
{
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.
    // 这里没有自旋锁
    // _objc_rootIsDeallocating()仅由_objc_storeWeak()调用
    // 它已经为我们获取了锁


    // fixme can't do this efficiently with os_lock_handoff_s
    // fixme 无法使用os_lock_handoff_s高效地执行此操作
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 返回是否找到条目且引用计数有释放标志
    return (it != table.refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}


// 检查对象是否被弱引用（侧边表版本）
bool 
objc_object::sidetable_isWeaklyReferenced() const
{
    // 初始化结果为false
    bool result = false;

    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
    // 锁定侧边表
    table.lock();

    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果找到条目
    if (it != table.refcnts.end()) {
        // 检查是否有弱引用标志
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    // 解锁侧边表
    table.unlock();

    // 返回结果
    return result;
}

// 如果定义了弱形成回调
#if OBJC_WEAK_FORMATION_CALLOUT_DEFINED
//Clients can dlsym() for this symbol to see if an ObjC supporting
//-_setWeaklyReferenced is present
// 客户端可以dlsym()此符号以查看是否支持-_setWeaklyReferenced的ObjC
// 导出符号，表示存在弱形成回调
OBJC_EXPORT const uintptr_t _objc_has_weak_formation_callout = 0;
// 静态断言：弱形成回调必须仅在支持非指针isa时定义
static_assert(SUPPORT_NONPOINTER_ISA, "Weak formation callout must only be defined when nonpointer isa is supported.");
#else
// 静态断言：如果弱回调不存在，则不能支持非指针isa
static_assert(!SUPPORT_NONPOINTER_ISA, "If weak callout is not present then we must not support nonpointer isas.");
#endif

// 在侧边表中设置弱引用标志（无锁版本）
void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA
    // 断言isa不是非指针
    ASSERT(!isa().nonpointer);
#endif
  
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];
  
    // 在引用计数中设置弱引用标志位
    table.refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
// 返回uintptr_t而不是bool，以便各种raw-isa -release路径都在eax中返回零
// 在侧边表中释放对象（减少引用计数）
uintptr_t
objc_object::sidetable_release(bool locked, bool performDealloc)
{
// 如果支持非指针isa
#if SUPPORT_NONPOINTER_ISA
    // 断言isa不是非指针
    ASSERT(!isa().nonpointer);
#endif
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // 是否需要执行dealloc的标志
    bool do_dealloc = false;

    // 如果未锁定，锁定侧边表
    if (!locked) table.lock();
    // 尝试插入或获取引用计数条目（如果不存在，初始化为释放状态）
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_DEALLOCATING);
    // 获取引用计数的引用
    auto &refcnt = it.first->second;
    // 如果是新插入的条目
    if (it.second) {
        // 需要执行dealloc
        do_dealloc = true;
    } 
    // 如果引用计数小于释放标记值（说明引用计数为0或接近0）
    else if (refcnt < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        // SIDE_TABLE_WEAKLY_REFERENCED可能已设置，不要更改它
        // 需要执行dealloc
        do_dealloc = true;
        // 设置释放标志
        refcnt |= SIDE_TABLE_DEALLOCATING;
    } 
    // 如果引用计数未被固定
    else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        // 减少引用计数
        refcnt -= SIDE_TABLE_RC_ONE;
    }
    // 解锁侧边表
    table.unlock();
    // 如果需要执行dealloc且允许执行
    if (do_dealloc  &&  performDealloc) {
        // 执行dealloc方法
        this->performDealloc();
    }
    // 返回是否需要执行dealloc（转换为uintptr_t）
    return do_dealloc;
}


// 清除侧边表中的正在释放状态
void 
objc_object::sidetable_clearDeallocating()
{
    // 获取对象对应的侧边表
    SideTable& table = SideTables()[this];

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    // 清除任何弱引用表项
    // 清除额外引用计数和释放位
    // (fixme 如果额外引用计数==0，警告或中止？)
    // 锁定侧边表
    table.lock();
    // 在引用计数映射中查找对象
    RefcountMap::iterator it = table.refcnts.find(this);
    // 如果找到条目
    if (it != table.refcnts.end()) {
        // 如果引用计数有弱引用标志
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            // 清除弱引用表中的条目（无锁版本，因为已经持有锁）
            weak_clear_no_lock(&table.weak_table, (id)this);
        }
        // 从引用计数映射中删除条目
        table.refcnts.erase(it);
    }
    // 解锁侧边表
    table.unlock();
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/

// 如果在ARM64上支持内联引用计数且不支持索引isa
#if ISA_HAS_INLINE_RC && !SUPPORT_INDEXED_ISA && __arm64__
// On ARM64 with nonpointer isa, objc_retain/release are provided by
// retain-release-helpers-arm64.s. We still need the C implementation for
// various slow paths. Expose those with _full suffixes.
// 在ARM64上使用非指针isa时，objc_retain/release由retain-release-helpers-arm64.s提供
// 我们仍然需要C实现用于各种慢路径
// 使用_full后缀暴露这些函数

// 完整版本的objc_retain（外部C函数）
extern "C" id objc_retain_full(id obj)
{
    // The assembly implementation has already performed the tagged-or-nil check.
    // 汇编实现已经执行了标记指针或nil检查
    // 断言对象不是标记指针或nil
    ASSERT(!_objc_isTaggedPointerOrNil(obj));
    // 调用对象的retain方法
    return obj->retain();
}

// 完整版本的objc_release（外部C函数）
extern "C" void objc_release_full(id obj)
{
    // The assembly implementation has already performed the tagged-or-nil check.
    // 汇编实现已经执行了标记指针或nil检查
    // 断言对象不是标记指针或nil
    ASSERT(!_objc_isTaggedPointerOrNil(obj));
    // 调用对象的release方法
    obj->release();
}

#else

// 内部retain函数（总是内联）
__attribute__((always_inline))
static id _Nullable _objc_retain(id _Nullable obj) {
    // 如果是标记指针或nil，直接返回
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    // 否则调用对象的retain方法
    return obj->retain();
}

// objc_retain函数（对齐16字节、扁平化、不内联）
__attribute__((aligned(16), flatten, noinline))
id
objc_retain(id obj)
{
    // 调用内部retain函数
    return _objc_retain(obj);
}

// 内部release函数（总是内联）
__attribute__((always_inline))
static void _objc_release(id _Nullable obj) {
    // 如果是标记指针或nil，直接返回
    if (_objc_isTaggedPointerOrNil(obj)) return;
    // 否则调用对象的release方法
    return obj->release();
}

// objc_release函数（对齐16字节、扁平化、不内联）
__attribute__((aligned(16), flatten, noinline))
void
objc_release(id obj)
{
    // 调用内部release函数
    return _objc_release(obj);
}

// 如果在ARM64架构上
#if __arm64__
// objc_release的x0寄存器版本（用于特定调用约定）
void
objc_release_x0(id obj)
{
    // 调用内部release函数
    return _objc_release(obj);
}

// objc_retain的x0寄存器版本（用于特定调用约定）
id
objc_retain_x0(id obj)
{
    // 调用内部retain函数
    return _objc_retain(obj);
}
#endif

#endif

// objc_autorelease函数（对齐16字节、扁平化、不内联）
__attribute__((aligned(16), flatten, noinline))
id
objc_autorelease(id obj)
{
    // 如果是标记指针或nil，直接返回
    if (_objc_isTaggedPointerOrNil(obj)) return obj;
    // 否则调用对象的autorelease方法
    return obj->autorelease();
}


// objc_isUniquelyReferenced函数（对齐16字节、扁平化、不内联）
__attribute__((aligned(16), flatten, noinline))
bool
objc_isUniquelyReferenced(id obj)
{
    // 如果是标记指针或nil，返回false
    if (_objc_isTaggedPointerOrNil(obj)) return false;
    // 否则调用对象的isUniquelyReferenced方法
    return obj->isUniquelyReferenced();
}


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

// 根类尝试保留操作
bool
_objc_rootTryRetain(id obj) 
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootTryRetain方法
    return obj->rootTryRetain();
}

// 根类检查是否正在释放
bool
_objc_rootIsDeallocating(id obj) 
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootIsDeallocating方法
    return obj->rootIsDeallocating();
}


// 清除对象的正在释放状态
void 
objc_clear_deallocating(id obj) 
{
    // 断言对象不为空
    ASSERT(obj);

    // 如果是标记指针，直接返回
    if (obj->isTaggedPointer()) return;
    // 否则调用对象的clearDeallocating方法
    obj->clearDeallocating();
}


// 根类检查释放是否为零
bool
_objc_rootReleaseWasZero(id obj)
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootReleaseShouldDealloc方法
    return obj->rootReleaseShouldDealloc();
}


// 根类自动释放操作（永不内联）
NEVER_INLINE id
_objc_rootAutorelease(id obj)
{
    // 断言对象不为空
    ASSERT(obj);
    // 调用对象的rootAutorelease方法
    return obj->rootAutorelease();
}

// 根类获取引用计数
uintptr_t
_objc_rootRetainCount(id obj)
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootRetainCount方法
    return obj->rootRetainCount();
}


// 根类保留操作（永不内联）
NEVER_INLINE id
_objc_rootRetain(id obj)
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootRetain方法
    return obj->rootRetain();
}

// 根类释放操作（永不内联）
NEVER_INLINE void
_objc_rootRelease(id obj)
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootRelease方法
    obj->rootRelease();
}

// Call [cls alloc] or [cls allocWithZone:nil], with appropriate
// shortcutting optimizations.
// 调用[cls alloc]或[cls allocWithZone:nil]，带有适当的快捷优化
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
    // 如果检查nil且类为nil（慢路径）
    if (slowpath(checkNil && !cls)) return nil;
    // 如果类没有自定义allocWithZone（快速路径）
    if (fastpath(!cls->ISA()->hasCustomAWZ())) {
        // 直接调用根类allocWithZone实现
        return _objc_rootAllocWithZone(cls, nil);
    }

    // No shortcuts available.
    // 没有可用的快捷方式
    // 如果使用allocWithZone
    if (allocWithZone) {
        // 调用allocWithZone:方法
        return ((id(*)(id, SEL, struct _NSZone *))objc_msgSend)(cls, @selector(allocWithZone:), nil);
    }
    // 否则调用alloc方法
    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
}


// Base class implementation of +alloc. cls is not nil.
// Calls [cls allocWithZone:nil].
// 基类的+alloc实现，cls不为nil
// 调用[cls allocWithZone:nil]
id
_objc_rootAlloc(Class cls)
{
    // 调用callAlloc，不检查nil，使用allocWithZone
    return callAlloc(cls, false/*checkNil*/, true/*allocWithZone*/);
}

// Calls [cls alloc].
// 调用[cls alloc]
id
objc_alloc(Class cls)
{
    // 调用callAlloc，检查nil，不使用allocWithZone
    return callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/);
}

// Calls [cls allocWithZone:nil].
// 调用[cls allocWithZone:nil]
id
objc_allocWithZone(Class cls)
{
    // 调用callAlloc，检查nil，使用allocWithZone
    return callAlloc(cls, true/*checkNil*/, true/*allocWithZone*/);
}

// Calls [[cls alloc] init].
// 调用[[cls alloc] init]
id
objc_alloc_init(Class cls)
{
    // 调用callAlloc分配对象，然后调用init方法
    return [callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/) init];
}

// Calls [cls new]
// 调用[cls new]
id
objc_opt_new(Class cls)
{
    // 如果类存在且没有自定义核心方法（快速路径）
    if (fastpath(cls && !cls->ISA()->hasCustomCore())) {
        // 直接调用alloc和init
        return [callAlloc(cls, false/*checkNil*/) init];
    }

    // 否则调用new方法
    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(new));
}

// Calls [obj self]
// 调用[obj self]
id
objc_opt_self(id obj)
{
    // 如果是标记指针或nil，或类没有自定义核心方法（快速路径）
    if (fastpath(_objc_isTaggedPointerOrNil(obj) || !obj->ISA()->hasCustomCore())) {
        // 直接返回对象自身
        return obj;
    }

    // 否则调用self方法
    return ((id(*)(id, SEL))objc_msgSend)(obj, @selector(self));
}

// Calls [obj class]
// 调用[obj class]
Class
objc_opt_class(id obj)
{
    // 如果对象为nil（慢路径）
    if (slowpath(!obj)) return nil;
    // 获取对象的类
    Class cls = obj->getIsa();
    // 如果类没有自定义核心方法（快速路径）
    if (fastpath(!cls->hasCustomCore())) {
        // 如果是元类，返回obj；否则返回cls
        return cls->isMetaClass() ? obj : cls;
    }

    // 否则调用class方法
    return ((Class(*)(id, SEL))objc_msgSend)(obj, @selector(class));
}

// Calls [obj isKindOfClass]
// 调用[obj isKindOfClass:]
BOOL
objc_opt_isKindOfClass(id obj, Class otherClass)
{
    // 如果对象为nil（慢路径）
    if (slowpath(!obj)) return NO;
    // 获取对象的类
    Class cls = obj->getIsa();
    // 如果类没有自定义核心方法（快速路径）
    if (fastpath(!cls->hasCustomCore())) {
        // 遍历类的继承链
        for (Class tcls = cls; tcls; tcls = tcls->getSuperclass()) {
            // 如果找到匹配的类，返回YES
            if (tcls == otherClass) return YES;
        }
        // 未找到匹配的类，返回NO
        return NO;
    }

    // 否则调用isKindOfClass:方法
    return ((BOOL(*)(id, SEL, Class))objc_msgSend)(obj, @selector(isKindOfClass:), otherClass);
}

// Calls [obj respondsToSelector]
// 调用[obj respondsToSelector:]
BOOL
objc_opt_respondsToSelector(id obj, SEL sel)
{
    // 如果对象为nil（慢路径）
    if (slowpath(!obj)) return NO;
    // 获取对象的类
    Class cls = obj->getIsa();
    // 如果类没有自定义核心方法（快速路径）
    if (fastpath(!cls->hasCustomCore())) {
        // 直接检查类是否响应选择器
        return class_respondsToSelector_inst(obj, sel, cls);
    }

    // 否则调用respondsToSelector:方法
    return ((BOOL(*)(id, SEL, SEL))objc_msgSend)(obj, @selector(respondsToSelector:), sel);
}

// 根类dealloc操作
void
_objc_rootDealloc(id obj)
{
    // 断言对象不为空
    ASSERT(obj);

    // 调用对象的rootDealloc方法
    obj->rootDealloc();
}

// 根类finalize操作（用于垃圾收集，当前未使用）
void
_objc_rootFinalize(id obj __unused)
{
    // 断言对象不为空
    ASSERT(obj);
    // 如果调用此函数，报告致命错误（垃圾收集已关闭）
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}


// 根类init操作
id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on this function.
    // Many classes do not properly chain -init calls.
    // 实际上，很难依赖此函数
    // 许多类没有正确链接-init调用
    // 直接返回对象（不做任何初始化）
    return obj;
}


// 根类zone操作
objc_zone_t
_objc_rootZone(id obj)
{
    // 忽略obj参数
    (void)obj;
    // allocWithZone under __OBJC2__ ignores the zone parameter
    // 在__OBJC2__下，allocWithZone忽略zone参数
// 如果支持zone
#if SUPPORT_ZONES
    // 返回默认malloc zone
    return malloc_default_zone();
#else
    // 否则返回nullptr
    return nullptr;
#endif
}

// 根类hash操作
uintptr_t
_objc_rootHash(id obj)
{
    // 返回对象的指针值作为hash
    return (uintptr_t)obj;
}

// 推入自动释放池
void *
objc_autoreleasePoolPush(void)
{
    // 调用AutoreleasePoolPage的push方法
    return AutoreleasePoolPage::push();
}

// 弹出自动释放池（永不内联）
NEVER_INLINE
void
objc_autoreleasePoolPop(void *ctxt)
{
    // 调用AutoreleasePoolPage的pop方法
    AutoreleasePoolPage::pop(ctxt);
}


// 推入自动释放池（内部版本）
void *
_objc_autoreleasePoolPush(void)
{
    // 调用objc_autoreleasePoolPush
    return objc_autoreleasePoolPush();
}

// 弹出自动释放池（内部版本）
void
_objc_autoreleasePoolPop(void *ctxt)
{
    // 调用objc_autoreleasePoolPop
    objc_autoreleasePoolPop(ctxt);
}

// 打印所有自动释放池（用于调试）
void 
_objc_autoreleasePoolPrint(void)
{
    // 调用AutoreleasePoolPage的printAll方法
    AutoreleasePoolPage::printAll();
}


// Same as objc_release but suitable for tail-calling 
// if you need the value back and don't want to push a frame before this point.
// 与objc_release相同，但适合尾调用
// 如果需要返回值且不想在此之前推送栈帧
__attribute__((noinline))
static id 
objc_releaseAndReturn(id obj)
{
    // 释放对象
    objc_release(obj);
    // 返回对象
    return obj;
}

// Same as objc_retainAutorelease but suitable for tail-calling 
// if you don't want to push a frame before this point.
// 与objc_retainAutorelease相同，但适合尾调用
// 如果不想在此之前推送栈帧
__attribute__((noinline))
static id 
objc_retainAutoreleaseAndReturn(id obj)
{
    // 调用objc_retainAutorelease
    return objc_retainAutorelease(obj);
}


// Prepare a value at +1 for return through a +0 autoreleasing convention.
// 准备一个+1的值，通过+0自动释放约定返回
id 
objc_autoreleaseReturnValue(id obj)
{
    // 如果优化返回成功，直接返回对象
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus1)) return obj;

    // 否则将对象添加到自动释放池
    return objc_autorelease(obj);
}

// Prepare a value at +0 for return through a +0 autoreleasing convention.
// 准备一个+0的值，通过+0自动释放约定返回
id 
objc_retainAutoreleaseReturnValue(id obj)
{
    // With return-address autorelease elision, we still need to retain the
    // object when prepare succeeds, because the claim side of the handoff
    // may not actually happen.
    // 使用返回地址自动释放省略时，当prepare成功时我们仍然需要保留对象
    // 因为移交的声明端可能实际上不会发生
// 如果支持返回地址自动释放省略
#if HAS_RETURNADDR_AUTORELEASE_ELISION
    // 如果优化返回成功，保留对象并返回
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus1)) return objc_retain(obj);
#else
    // 否则如果优化返回成功，直接返回对象
    if (prepareOptimizedReturn(obj, false, ReturnAtPlus0)) return obj;
#endif

    // not objc_autoreleaseReturnValue(objc_retain(obj)) 
    // because we don't need another optimization attempt
    // 不是objc_autoreleaseReturnValue(objc_retain(obj))
    // 因为我们不需要另一次优化尝试
    // 调用objc_retainAutoreleaseAndReturn
    return objc_retainAutoreleaseAndReturn(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1.
// 接受通过+0自动释放约定返回的值，用于+1使用
id
objc_retainAutoreleasedReturnValue(id obj)
{
    // 如果接受优化返回成功（期望NOP），直接返回对象
    if (acceptOptimizedReturn(/*expectsNop*/true) == ReturnAtPlus1) return obj;

    // 否则保留对象
    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1,
// without a NOP in the caller on ARM64.
// 接受通过+0自动释放约定返回的值，用于+1使用
// 在ARM64上调用者中没有NOP
id
objc_claimAutoreleasedReturnValue(id obj)
{
    // 如果接受优化返回成功（不期望NOP），直接返回对象
    if (acceptOptimizedReturn(/*expectsNop*/false) == ReturnAtPlus1) return obj;

    // 否则保留对象
    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +0.
// 接受通过+0自动释放约定返回的值，用于+0使用
id
objc_unsafeClaimAutoreleasedReturnValue(id obj)
{
    // 如果接受优化返回成功（期望NOP）
    if (acceptOptimizedReturn(/*expectsNop*/true) == ReturnAtPlus1)
        // 释放对象并返回
        return objc_releaseAndReturn(obj);

    // 否则直接返回对象
    return obj;
}

// 保留并自动释放对象
id
objc_retainAutorelease(id obj)
{
    // 先保留对象，然后自动释放
    return objc_autorelease(objc_retain(obj));
}

// 在主线程上执行dealloc的辅助函数
void
_objc_deallocOnMainThreadHelper(void *context)
{
    // 将上下文转换为对象
    id obj = (id)context;
    // 调用对象的dealloc方法
    [obj dealloc];
}

// convert objc_objectptr_t to id, callee must take ownership.
// 将objc_objectptr_t转换为id，调用者必须取得所有权
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
// 将objc_objectptr_t转换为id，不转移所有权
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
// 将id转换为objc_objectptr_t，不转移所有权
objc_objectptr_t objc_unretainedPointer(id object) { return object; }

// 初始化侧边表
void side_tables_init(void)
{
    // 初始化侧边表映射
    SideTablesMap.init();
}

// 初始化自动释放和返回信息
void arr_init(void)
{
    // 初始化关联对象
    _objc_associations_init();
    // 初始化返回自动释放信息的第一个字TLS
    ReturnAutoreleaseInfo::tlsFirstWord.init();
    // 初始化返回自动释放信息的返回地址TLS
    ReturnAutoreleaseInfo::tlsReturnAddress.init();
    // 初始化自动释放池页TLS
    AutoreleasePoolPage::initTLS();

    // 如果启用了调试扫描弱表
    if (DebugScanWeakTables)
        // 启动弱表扫描线程
        startWeakTableScan();
}


// 如果支持标记指针
#if SUPPORT_TAGGED_POINTERS

// Placeholder for old debuggers. When they inspect an 
// extended tagged pointer object they will see this isa.
// 旧调试器的占位符。当它们检查扩展标记指针对象时，将看到此isa

// 声明未识别的标记指针类
@interface __NSUnrecognizedTaggedPointer : NSObject
@end

// 实现未识别的标记指针类（非懒加载类）
__attribute__((objc_nonlazy_class))
@implementation __NSUnrecognizedTaggedPointer
// retain方法：返回自身
-(id) retain { return self; }
// release方法：空操作
-(oneway void) release { }
// autorelease方法：返回自身
-(id) autorelease { return self; }
@end

#endif

// NSObject类实现（非懒加载类）
__attribute__((objc_nonlazy_class))
@implementation NSObject

// 类方法：initialize，用于类初始化
+ (void)initialize {
}

// 类方法：self，返回类对象自身
+ (id)self {
    // 返回类对象自身
    return (id)self;
}

// 实例方法：self，返回实例自身
- (id)self {
    // 返回实例自身
    return self;
}

// 类方法：class，返回类对象自身
+ (Class)class {
    // 返回类对象自身
    return self;
}

// 实例方法：class，返回对象的类
- (Class)class {
    // 获取对象的类
    return object_getClass(self);
}

// 类方法：superclass，返回父类
+ (Class)superclass {
    // 返回类的父类
    return self->getSuperclass();
}

// 实例方法：superclass，返回对象的父类
- (Class)superclass {
    // 返回对象类的父类
    return [self class]->getSuperclass();
}

// 类方法：isMemberOfClass，检查类对象是否是特定类的成员
+ (BOOL)isMemberOfClass:(Class)cls {
    // 检查类的isa是否等于给定类
    return self->ISA() == cls;
}

// 实例方法：isMemberOfClass，检查对象是否是特定类的成员
- (BOOL)isMemberOfClass:(Class)cls {
    // 检查对象的类是否等于给定类
    return [self class] == cls;
}

// 类方法：isKindOfClass，检查类对象是否是特定类或其子类
+ (BOOL)isKindOfClass:(Class)cls {
    // 遍历类的继承链
    for (Class tcls = self->ISA(); tcls; tcls = tcls->getSuperclass()) {
        // 如果找到匹配的类，返回YES
        if (tcls == cls) return YES;
    }
    // 未找到匹配的类，返回NO
    return NO;
}

// 实例方法：isKindOfClass，检查对象是否是特定类或其子类
- (BOOL)isKindOfClass:(Class)cls {
    // 遍历对象类的继承链
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        // 如果找到匹配的类，返回YES
        if (tcls == cls) return YES;
    }
    // 未找到匹配的类，返回NO
    return NO;
}

// 类方法：isSubclassOfClass，检查类是否是特定类的子类
+ (BOOL)isSubclassOfClass:(Class)cls {
    // 遍历类的继承链
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        // 如果找到匹配的类，返回YES
        if (tcls == cls) return YES;
    }
    // 未找到匹配的类，返回NO
    return NO;
}

// 类方法：isAncestorOfObject，检查类是否是对象的祖先类
+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    // 遍历对象类的继承链
    for (Class tcls = [obj class]; tcls; tcls = tcls->getSuperclass()) {
        // 如果找到匹配的类，返回YES
        if (tcls == self) return YES;
    }
    // 未找到匹配的类，返回NO
    return NO;
}

// 类方法：instancesRespondToSelector，检查实例是否响应选择器
+ (BOOL)instancesRespondToSelector:(SEL)sel {
    // 检查类是否响应实例方法选择器
    return class_respondsToSelector_inst(nil, sel, self);
}

// 类方法：respondsToSelector，检查类对象是否响应选择器
+ (BOOL)respondsToSelector:(SEL)sel {
    // 检查类对象是否响应选择器
    return class_respondsToSelector_inst(self, sel, self->ISA());
}

// 实例方法：respondsToSelector，检查对象是否响应选择器
- (BOOL)respondsToSelector:(SEL)sel {
    // 检查对象是否响应选择器
    return class_respondsToSelector_inst(self, sel, [self class]);
}

// 类方法：conformsToProtocol，检查类是否遵循协议
+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    // 如果协议为nil，返回NO
    if (!protocol) return NO;
    // 遍历类的继承链
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        // 如果类遵循协议，返回YES
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    // 未找到遵循协议的类，返回NO
    return NO;
}

// 实例方法：conformsToProtocol，检查对象是否遵循协议
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    // 如果协议为nil，返回NO
    if (!protocol) return NO;
    // 遍历对象类的继承链
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        // 如果类遵循协议，返回YES
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    // 未找到遵循协议的类，返回NO
    return NO;
}

// 类方法：hash，返回类对象的hash值
+ (NSUInteger)hash {
    // 调用根类hash函数
    return _objc_rootHash(self);
}

// 实例方法：hash，返回对象的hash值
- (NSUInteger)hash {
    // 调用根类hash函数
    return _objc_rootHash(self);
}

// 类方法：isEqual，检查类对象是否相等
+ (BOOL)isEqual:(id)obj {
    // 检查对象是否等于类对象自身
    return obj == (id)self;
}

// 实例方法：isEqual，检查对象是否相等
- (BOOL)isEqual:(id)obj {
    // 检查对象是否等于自身
    return obj == self;
}


// 类方法：isFault，检查类对象是否是fault（用于Core Data）
+ (BOOL)isFault {
    // 默认返回NO
    return NO;
}

// 实例方法：isFault，检查对象是否是fault（用于Core Data）
- (BOOL)isFault {
    // 默认返回NO
    return NO;
}

// 类方法：isProxy，检查类对象是否是代理
+ (BOOL)isProxy {
    // 默认返回NO
    return NO;
}

// 实例方法：isProxy，检查对象是否是代理
- (BOOL)isProxy {
    // 默认返回NO
    return NO;
}


// 类方法：instanceMethodForSelector，获取实例方法的实现
+ (IMP)instanceMethodForSelector:(SEL)sel {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 获取类的实例方法实现
    return class_getMethodImplementation(self, sel);
}

// 类方法：methodForSelector，获取类方法的实现
+ (IMP)methodForSelector:(SEL)sel {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 获取类对象的方法实现
    return object_getMethodImplementation((id)self, sel);
}

// 实例方法：methodForSelector，获取实例方法的实现
- (IMP)methodForSelector:(SEL)sel {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 获取对象的方法实现
    return object_getMethodImplementation(self, sel);
}

// 类方法：resolveClassMethod，解析类方法（默认返回NO）
+ (BOOL)resolveClassMethod:(SEL)sel {
    // 默认不解析，返回NO
    return NO;
}

// 类方法：resolveInstanceMethod，解析实例方法（默认返回NO）
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    // 默认不解析，返回NO
    return NO;
}

// Replaced by CF (throws an NSException)
// 由CF替换（抛出NSException）
// 类方法：doesNotRecognizeSelector，处理未识别的选择器
+ (void)doesNotRecognizeSelector:(SEL)sel {
    // 报告致命错误：未识别的选择器发送到类对象
    _objc_fatal("+[%s %s]: unrecognized selector sent to instance %p", 
                class_getName(self), sel_getName(sel), self);
}

// Replaced by CF (throws an NSException)
// 由CF替换（抛出NSException）
// 实例方法：doesNotRecognizeSelector，处理未识别的选择器
- (void)doesNotRecognizeSelector:(SEL)sel {
    // 报告致命错误：未识别的选择器发送到实例
    _objc_fatal("-[%s %s]: unrecognized selector sent to instance %p", 
                object_getClassName(self), sel_getName(sel), self);
}


// 类方法：performSelector，执行选择器（无参数）
+ (id)performSelector:(SEL)sel {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL))objc_msgSend)((id)self, sel);
}

// 类方法：performSelector:withObject，执行选择器（一个参数）
+ (id)performSelector:(SEL)sel withObject:(id)obj {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL, id))objc_msgSend)((id)self, sel, obj);
}

// 类方法：performSelector:withObject:withObject，执行选择器（两个参数）
+ (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL, id, id))objc_msgSend)((id)self, sel, obj1, obj2);
}

// 实例方法：performSelector，执行选择器（无参数）
- (id)performSelector:(SEL)sel {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL))objc_msgSend)(self, sel);
}

// 实例方法：performSelector:withObject，执行选择器（一个参数）
- (id)performSelector:(SEL)sel withObject:(id)obj {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL, id))objc_msgSend)(self, sel, obj);
}

// 实例方法：performSelector:withObject:withObject，执行选择器（两个参数）
- (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    // 如果选择器为nil，调用doesNotRecognizeSelector
    if (!sel) [self doesNotRecognizeSelector:sel];
    // 调用objc_msgSend执行选择器
    return ((id(*)(id, SEL, id, id))objc_msgSend)(self, sel, obj1, obj2);
}


// Replaced by CF (returns an NSMethodSignature)
// 由CF替换（返回NSMethodSignature）
// 类方法：instanceMethodSignatureForSelector，获取实例方法签名
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel {
    // 报告致命错误：需要CoreFoundation
    _objc_fatal("+[NSObject instanceMethodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
// 由CF替换（返回NSMethodSignature）
// 类方法：methodSignatureForSelector，获取类方法签名
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    // 报告致命错误：需要CoreFoundation
    _objc_fatal("+[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
// 由CF替换（返回NSMethodSignature）
// 实例方法：methodSignatureForSelector，获取实例方法签名
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    // 报告致命错误：需要CoreFoundation
    _objc_fatal("-[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// 类方法：forwardInvocation，转发调用
+ (void)forwardInvocation:(NSInvocation *)invocation {
    // 调用doesNotRecognizeSelector处理未识别的选择器
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

// 实例方法：forwardInvocation，转发调用
- (void)forwardInvocation:(NSInvocation *)invocation {
    // 调用doesNotRecognizeSelector处理未识别的选择器
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

// 类方法：forwardingTargetForSelector，获取转发目标
+ (id)forwardingTargetForSelector:(SEL)sel {
    // 默认返回nil
    return nil;
}

// 实例方法：forwardingTargetForSelector，获取转发目标
- (id)forwardingTargetForSelector:(SEL)sel {
    // 默认返回nil
    return nil;
}


// Replaced by CF (returns an NSString)
// 由CF替换（返回NSString）
// 类方法：description，返回类对象的描述
+ (NSString *)description {
    // 默认返回nil
    return nil;
}

// Replaced by CF (returns an NSString)
// 由CF替换（返回NSString）
// 实例方法：description，返回对象的描述
- (NSString *)description {
    // 默认返回nil
    return nil;
}

// 类方法：debugDescription，返回类对象的调试描述
+ (NSString *)debugDescription {
    // 返回description的结果
    return [self description];
}

// 实例方法：debugDescription，返回对象的调试描述
- (NSString *)debugDescription {
    // 返回description的结果
    return [self description];
}


// 类方法：new，创建并初始化新对象
+ (id)new {
    // 调用callAlloc分配对象，然后调用init
    return [callAlloc(self, false/*checkNil*/) init];
}

// 类方法：retain，保留类对象（类对象不需要引用计数）
+ (id)retain {
    // 直接返回类对象自身
    return (id)self;
}

// Replaced by ObjectAlloc
// 由ObjectAlloc替换
// 实例方法：retain，保留对象
- (id)retain {
    // 调用根类retain函数
    return _objc_rootRetain(self);
}


// 类方法：_tryRetain，尝试保留类对象
+ (BOOL)_tryRetain {
    // 类对象总是可以保留，返回YES
    return YES;
}

// Replaced by ObjectAlloc
// 由ObjectAlloc替换
// 实例方法：_tryRetain，尝试保留对象
- (BOOL)_tryRetain {
    // 调用根类tryRetain函数
    return _objc_rootTryRetain(self);
}

// 类方法：_isDeallocating，检查类对象是否正在释放
+ (BOOL)_isDeallocating {
    // 类对象不会释放，返回NO
    return NO;
}

// 实例方法：_isDeallocating，检查对象是否正在释放
- (BOOL)_isDeallocating {
    // 调用根类isDeallocating函数
    return _objc_rootIsDeallocating(self);
}

// 类方法：allowsWeakReference，检查类对象是否允许弱引用
+ (BOOL)allowsWeakReference { 
    // 类对象总是允许弱引用，返回YES
    return YES; 
}

// 类方法：retainWeakReference，保留弱引用（类对象）
+ (BOOL)retainWeakReference {
    // 类对象总是可以保留弱引用，返回YES
    return YES; 
}

// 实例方法：allowsWeakReference，检查对象是否允许弱引用
- (BOOL)allowsWeakReference { 
    // 如果对象不在释放中，允许弱引用
    return ! [self _isDeallocating]; 
}

// 实例方法：retainWeakReference，保留弱引用
- (BOOL)retainWeakReference { 
    // 尝试保留对象
    return [self _tryRetain]; 
}

// 类方法：release，释放类对象（类对象不需要引用计数）
+ (oneway void)release {
    // 空操作
}

// Replaced by ObjectAlloc
// 由ObjectAlloc替换
// 实例方法：release，释放对象
- (oneway void)release {
    // 调用根类release函数
    _objc_rootRelease(self);
}

// 类方法：autorelease，自动释放类对象
+ (id)autorelease {
    // 直接返回类对象自身
    return (id)self;
}

// Replaced by ObjectAlloc
// 由ObjectAlloc替换
// 实例方法：autorelease，自动释放对象
- (id)autorelease {
    // 调用根类autorelease函数
    return _objc_rootAutorelease(self);
}

// 类方法：retainCount，获取类对象的引用计数
+ (NSUInteger)retainCount {
    // 类对象返回最大无符号长整型值
    return ULONG_MAX;
}

// 实例方法：retainCount，获取对象的引用计数
- (NSUInteger)retainCount {
    // 调用根类retainCount函数
    return _objc_rootRetainCount(self);
}

// 类方法：alloc，分配对象
+ (id)alloc {
    // 调用根类alloc函数
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
// 由ObjectAlloc替换
// 类方法：allocWithZone，在指定zone中分配对象
+ (id)allocWithZone:(struct _NSZone *)zone {
    // 调用根类allocWithZone函数
    return _objc_rootAllocWithZone(self, (objc_zone_t)zone);
}

// Replaced by CF (throws an NSException)
// 由CF替换（抛出NSException）
// 类方法：init，初始化类对象
+ (id)init {
    // 直接返回类对象自身
    return (id)self;
}

// 实例方法：init，初始化对象
- (id)init {
    // 调用根类init函数
    return _objc_rootInit(self);
}

// Replaced by CF (throws an NSException)
// 由CF替换（抛出NSException）
// 类方法：dealloc，释放类对象
+ (void)dealloc {
    // 空操作
}


// Replaced by NSZombies
// 由NSZombies替换
// 实例方法：dealloc，释放对象
- (void)dealloc {
    // 调用根类dealloc函数
    _objc_rootDealloc(self);
}

// Previously used by GC. Now a placeholder for binary compatibility.
// 以前用于GC。现在是为了二进制兼容性的占位符
// 实例方法：finalize，完成对象（已废弃）
- (void) finalize {
    // 空操作
}

// 类方法：zone，获取类对象的zone
+ (struct _NSZone *)zone {
    // 调用根类zone函数
    return (struct _NSZone *)_objc_rootZone(self);
}

// 实例方法：zone，获取对象的zone
- (struct _NSZone *)zone {
    // 调用根类zone函数
    return (struct _NSZone *)_objc_rootZone(self);
}

// 类方法：copy，复制类对象
+ (id)copy {
    // 直接返回类对象自身
    return (id)self;
}

// 类方法：copyWithZone，在指定zone中复制类对象
+ (id)copyWithZone:(struct _NSZone *)zone {
    // 直接返回类对象自身
    return (id)self;
}

// 实例方法：copy，复制对象
- (id)copy {
    // 调用copyWithZone方法，zone为nil
    return [(id)self copyWithZone:nil];
}

// 类方法：mutableCopy，可变复制类对象
+ (id)mutableCopy {
    // 直接返回类对象自身
    return (id)self;
}

// 类方法：mutableCopyWithZone，在指定zone中可变复制类对象
+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    // 直接返回类对象自身
    return (id)self;
}

// 实例方法：mutableCopy，可变复制对象
- (id)mutableCopy {
    // 调用mutableCopyWithZone方法，zone为nil
    return [(id)self mutableCopyWithZone:nil];
}

// NSObject类实现结束
@end


