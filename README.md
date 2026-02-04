# NSObject.mm

注释内容包括：

1. 头文件包含和调试符号定义
2. 分配失败处理函数
3. Swift 引用计数互操作性
4. 侧边表定义和锁定机制
5. 弱引用操作（storeWeak、objc_storeWeak 等）
6. 自动释放池实现（AutoreleasePoolPage 类及其方法）
7. 引用计数操作函数（retain、release、autorelease 等）
8. 侧边表相关函数（sidetable_retain、sidetable_release 等）
9. 根类操作函数（objc_rootRetain、_objc_rootRelease 等）
10. NSObject 类的方法实现（self、class、isKindOfClass 等）

# objc-weak.h和objc-weak.mm

注释内容包括：

### objc-weak.h：

1. 头文件保护和包含
2. 弱引用表说明
3. 类型定义（weak_referrer_t）
4. 常量定义（PTR_MINUS_2、WEAK_INLINE_COUNT、REFERRERS_OUT_OF_LINE）
5. weak_entry_t 结构体（内联/外联存储）
6. weak_table_t 结构体
7. WeakRegisterDeallocatingOptions 枚举
8. 函数声明

### objc-weak.mm：

1. 头文件包含和宏定义
2. 错误处理函数
3. 哈希函数（hash_pointer、w_hash_pointer）
4. 弱引用者管理（grow_refs_and_insert、append_referrer、remove_referrer）
5. 弱引用表管理（weak_entry_insert、weak_resize、weak_grow_maybe、weak_compact_maybe、weak_entry_remove）
6. 查找函数（weak_entry_for_referent）
7. 注册/注销函数（weak_register_no_lock、weak_unregister_no_lock）
8. 清理函数（weak_clear_no_lock）