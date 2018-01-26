//
//  LSCModuleExporter.m
//  LuaScriptCore
//
//  Created by 冯鸿杰 on 2017/9/5.
//  Copyright © 2017年 vimfung. All rights reserved.
//

#import "LSCExportsTypeManager.h"
#import "LSCContext_Private.h"
#import "LSCSession_Private.h"
#import "LSCEngineAdapter.h"
#import "LSCValue_Private.h"
#import "LSCPointer.h"
#import "LSCExportTypeDescriptor+Private.h"
#import "LSCExportMethodDescriptor.h"
#import "LSCExportTypeAnnotation.h"
#import "LSCExportPropertyDescriptor.h"
#import "LSCVirtualInstance.h"
#import <objc/runtime.h>

@interface LSCExportsTypeManager ()

/**
 上下文对象
 */
@property (nonatomic, weak) LSCContext *context;

/**
 导出类型描述集合
 */
@property (nonatomic, strong) NSMutableDictionary<NSString *, LSCExportTypeDescriptor *> *exportTypes;

/**
 导出类型映射表
 */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *exportTypesMapping;

@end

@implementation LSCExportsTypeManager

- (instancetype)initWithContext:(LSCContext *)context
{
    if (self = [super init])
    {
        self.context = context;
        
        self.exportTypes = [NSMutableDictionary dictionary];
        self.exportTypesMapping = [NSMutableDictionary dictionary];
        
        //初始化导出类型
        [self _setupExportsTypes];
        
        //设置环境
        [self _setupExportEnv];
    }
    
    return self;
}

- (BOOL)checkExportsTypeWithObject:(id)object
{
    LSCExportTypeDescriptor *typeDescriptor = [self _typeDescriptorWithObject:object];
    if (typeDescriptor)
    {
        return YES;
    }
    
    return NO;
}

- (void)createLuaObjectByObject:(id)object
{
    LSCExportTypeDescriptor *typeDescriptor = [self _typeDescriptorWithObject:object];
    if (typeDescriptor)
    {
        lua_State *state = self.context.currentSession.state;
        [LSCEngineAdapter getGlobal:state name:typeDescriptor.typeName.UTF8String];
        [LSCEngineAdapter pop:state count:1];
        
        [self _initLuaObjectWithObject:object type:typeDescriptor];
    }
}

#pragma mark - Private

/**
 设置导出环境
 */
- (void)_setupExportEnv
{
    //为_G设置元表，用于监听其对象的获取，从而找出哪些是导出类型
    lua_State *state = self.context.currentSession.state;
    [LSCEngineAdapter getGlobal:state name:"_G"];
    
    if (![LSCEngineAdapter isTable:state index:-1])
    {
        [LSCEngineAdapter error:state message:"Invalid '_G' object，setup the exporter fail."];
        [LSCEngineAdapter pop:state count:1];
        return;
    }
    
    //创建_G元表
    [LSCEngineAdapter newTable:state];
    
    //监听__index元方法
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushCClosure:globalIndexMetaMethodHandler n:1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__index"];
    
    //绑定为_G元表
    [LSCEngineAdapter setMetatable:state index:-2];
    
    [LSCEngineAdapter pop:state count:1];
}

/**
 初始化导出类型
 */
- (void)_setupExportsTypes
{
    //注册基类Object
    LSCExportTypeDescriptor *objectTypeDescriptor = [LSCExportTypeDescriptor objectTypeDescriptor];
    [self.exportTypes setObject:objectTypeDescriptor forKey:objectTypeDescriptor.typeName];
    
    //反射所有类型,并找出所有导出类型
    uint numClasses;
    
    Class *classList = objc_copyClassList(&numClasses);
    
    for (int i = 0; i < numClasses; i++)
    {
        Class cls = *(classList + i);
        
        if (class_getClassMethod(cls, @selector(conformsToProtocol:))
            && [cls conformsToProtocol:@protocol(LSCExportType)])
        {
            LSCExportTypeDescriptor *typeDescriptor = [[LSCExportTypeDescriptor alloc] initWithTypeName:[self _typeNameWithClass:cls]
                                                                                             nativeType:cls];

            [self.exportTypes setObject:typeDescriptor
                                 forKey:typeDescriptor.typeName];
            [self.exportTypesMapping setObject:typeDescriptor.typeName
                                        forKey:NSStringFromClass(cls)];
        }
    }
    
    free(classList);
}

/**
 准备导出类型到Lua中

 @param typeDescriptor 类型描述
 */
- (void)_prepareExportsTypeWithDescriptor:(LSCExportTypeDescriptor *)typeDescriptor
{
    lua_State *state = self.context.currentSession.state;

    //判断父类是否为导出类型
    LSCExportTypeDescriptor *parentTypeDescriptor = [self _findParentTypeDescriptorWithTypeDescriptor:typeDescriptor];
    if (parentTypeDescriptor)
    {
        //导入父级类型
        [LSCEngineAdapter getGlobal:state name:parentTypeDescriptor.typeName.UTF8String];
        [LSCEngineAdapter pop:state count:1];
    }
    
    [self _exportsType:typeDescriptor state:state];
}

/**
 导出类型

 @param typeDescriptor 类型描述
 @param state Lua状态
 */
- (void)_exportsType:(LSCExportTypeDescriptor *)typeDescriptor state:(lua_State *)state
{
    //创建类模块
    [LSCEngineAdapter newTable:state];
    
    //设置类名, since ver 1.3
    [LSCEngineAdapter pushString:typeDescriptor.typeName.UTF8String state:state];
    [LSCEngineAdapter setField:state index:-2 name:"name"];
    
    //关联本地类型
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)(typeDescriptor) state:state];
    [LSCEngineAdapter setField:state index:-2 name:"_nativeType"];

    /**
     fixed : 由于OC中类方法存在继承关系，因此，直接导出某个类定义的类方法无法满足这种继承关系。
     例如：moduleName方法在Object中定义，但是当其子类调用时由于只能取到当前导出方法的类型(Object)，无法取到调用方法的类型(即Object的子类)，因此导致逻辑处理的异常。
     所以，该处改为导出其继承的所有类方法来满足该功能需要。
     **/
    //导出声明的类方法
    [self _exportsClassMethods:typeDescriptor state:state];

    //添加创建对象方法
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushCClosure:objectCreateHandler n:2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"create"];

    //添加子类化对象方法
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushCClosure:subClassHandler n:2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"subclass"];

    //增加子类判断方法, since ver 1.3
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushCClosure:subclassOfHandler n:2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"subclassOf"];
    
    //关联索引
    [LSCEngineAdapter pushValue:-1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__index"];
    
    //类型描述
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushCClosure:classToStringHandler n:2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__tostring"];
    
    //获取父类型
    LSCExportTypeDescriptor *parentTypeDescriptor = typeDescriptor.parentTypeDescriptor;

    //关联父类模块
    if (parentTypeDescriptor)
    {
        //存在父类，则直接设置父类为元表
        [LSCEngineAdapter getGlobal:state name:parentTypeDescriptor.typeName.UTF8String];
        if ([LSCEngineAdapter isTable:state index:-1])
        {
            //设置父类指向
            [LSCEngineAdapter pushValue:-1 state:state];
            [LSCEngineAdapter setField:state index:-3 name:"super"];
            
            //关联元表
            [LSCEngineAdapter setMetatable:state index:-2];
        }
        else
        {
            [LSCEngineAdapter pop:state count:1];
        }
    }
    else
    {
        //Object需要创建一个新table来作为元表，否则无法使用元方法，如：print(Object);
        [LSCEngineAdapter newTable:state];
        
        //类型描述
        [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
        [LSCEngineAdapter pushCClosure:classToStringHandler n:1 state:state];
        [LSCEngineAdapter setField:state index:-2 name:"__tostring"];

        [LSCEngineAdapter setMetatable:state index:-2];
    }

    [LSCEngineAdapter setGlobal:state name:typeDescriptor.typeName.UTF8String];

    //---------创建实例对象原型表---------------
    [LSCEngineAdapter newMetatable:state name:typeDescriptor.prototypeTypeName.UTF8String];

    [LSCEngineAdapter getGlobal:state name:typeDescriptor.typeName.UTF8String];
    [LSCEngineAdapter setField:state index:-2 name:"class"];

    [LSCEngineAdapter pushLightUserdata:(__bridge void *)(typeDescriptor) state:state];
    [LSCEngineAdapter setField:state index:-2 name:"_nativeType"];

    [LSCEngineAdapter pushValue:-1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__index"];
    
    //增加__newindex元方法监听，主要用于原型中注册属性
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushCClosure:prototypeNewIndexHandler n:1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__newindex"];

//    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
//    [LSCEngineAdapter pushCClosure:objectDestroyHandler n:1 state:state];
//    [LSCEngineAdapter setField:state index:-2 name:"__gc"];

    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushCClosure:prototypeToStringHandler n:2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__tostring"];

    //给类元表绑定该实例元表
    [LSCEngineAdapter getGlobal:state name:typeDescriptor.typeName.UTF8String];
    [LSCEngineAdapter pushValue:-2 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"prototype"];
    [LSCEngineAdapter pop:state count:1];
    
    //导出属性
    NSArray<NSString *> *propertySelectorList = [self _exportsProperties:typeDescriptor state:state];

    //导出实例方法
    [self _exportsInstanceMethods:typeDescriptor
             propertySelectorList:propertySelectorList
                            state:state];

    if (parentTypeDescriptor)
    {
        //关联父类
        [LSCEngineAdapter getMetatable:state name:parentTypeDescriptor.prototypeTypeName.UTF8String];
        if ([LSCEngineAdapter isTable:state index:-1])
        {
            //设置父类访问属性 since ver 1.3
            [LSCEngineAdapter pushValue:-1 state:state];
            [LSCEngineAdapter setField:state index:-3 name:"super"];
            
            //设置父类元表
            [LSCEngineAdapter setMetatable:state index:-2];
        }
        else
        {
            [LSCEngineAdapter pop:state count:1];
        }
        
    }
    else
    {
        //Object需要创建一个新table来作为元表，否则无法使用元方法，如：print(Object);
        [LSCEngineAdapter newTable:state];
        
//        [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
//        [LSCEngineAdapter pushCClosure:objectDestroyHandler n:1 state:state];
//        [LSCEngineAdapter setField:state index:-2 name:"__gc"];
        
        [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
        [LSCEngineAdapter pushCClosure:prototypeToStringHandler n:1 state:state];
        [LSCEngineAdapter setField:state index:-2 name:"__tostring"];
        
        [LSCEngineAdapter setMetatable:state index:-2];
        
        //Object类需要增加一些特殊方法
        //创建instanceOf方法 since ver 1.3
        [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
        [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
        [LSCEngineAdapter pushCClosure:instanceOfHandler n:2 state:state];
        [LSCEngineAdapter setField:state index:-2 name:"instanceOf"];
    }
    
    [LSCEngineAdapter pop:state count:1];
}

- (void)_exportsClassMethods:(LSCExportTypeDescriptor *)typeDescriptor
                  targetType:(LSCExportTypeDescriptor *)targetTypeDescriptor
                       state:(lua_State *)state
{
    if (targetTypeDescriptor.nativeType != NULL)
    {
        NSArray *excludesMethodNames = nil;
        Class metaType = objc_getMetaClass(NSStringFromClass(targetTypeDescriptor.nativeType).UTF8String);
        
        //先判断是否有实现注解的排除类方法
        if (class_conformsToProtocol(targetTypeDescriptor.nativeType, @protocol(LSCExportTypeAnnotation)))
        {
            if ([self _declareClassMethodResponderToSelector:@selector(excludeExportClassMethods) withClass:targetTypeDescriptor.nativeType])
            {
                excludesMethodNames = [targetTypeDescriptor.nativeType excludeExportClassMethods];
            }
        }
        
        NSArray *builtInExcludeMethodNames = @[@"typeName",
                                               @"excludeExportClassMethods",
                                               @"excludeProperties",
                                               @"excludeExportInstanceMethods"];
        
        //解析方法
        NSMutableDictionary *methodDict = [typeDescriptor.classMethods mutableCopy];
        if (!methodDict)
        {
            methodDict = [NSMutableDictionary dictionary];
        }
        
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(metaType, &methodCount);
        for (const Method *m = methods; m < methods + methodCount; m ++)
        {
            SEL selector = method_getName(*m);
            
            NSString *selectorName = NSStringFromSelector(selector);
            if (![selectorName hasPrefix:@"_"]
                && ![selectorName hasPrefix:@"."]
                && ![builtInExcludeMethodNames containsObject:selectorName]
                && ![excludesMethodNames containsObject:selectorName])
            {
                NSString *luaMethodName = [self _getLuaMethodNameWithSelectorName:selectorName];
                
                //判断是否已导出
                __block BOOL hasExists = NO;
                [LSCEngineAdapter getField:state index:-1 name:luaMethodName.UTF8String];
                if (![LSCEngineAdapter isNil:state index:-1])
                {
                    hasExists = YES;
                }
                [LSCEngineAdapter pop:state count:1];
                
                if (!hasExists)
                {
                    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
                    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
                    [LSCEngineAdapter pushString:luaMethodName.UTF8String state:state];
                    [LSCEngineAdapter pushCClosure:classMethodRouteHandler n:3 state:state];
                    
                    [LSCEngineAdapter setField:state index:-2 name:luaMethodName.UTF8String];
                }
                
                NSMutableArray<LSCExportMethodDescriptor *> *methodList = methodDict[luaMethodName];
                if (!methodList)
                {
                    methodList = [NSMutableArray array];
                    [methodDict setObject:methodList forKey:luaMethodName];
                }
                
                //获取方法签名
                NSString *signStr = [self _getMethodSign:*m];
                
                hasExists = NO;
                [methodList enumerateObjectsUsingBlock:^(LSCExportMethodDescriptor * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                   
                    if ([obj.paramsSignature isEqualToString:signStr])
                    {
                        hasExists = YES;
                        *stop = YES;
                    }
                    
                }];
                
                if (!hasExists)
                {
                    NSMethodSignature *sign = [targetTypeDescriptor.nativeType methodSignatureForSelector:selector];
                    LSCExportMethodDescriptor *methodDesc = [[LSCExportMethodDescriptor alloc] initWithSelector:selector methodSignature:sign paramsSignature:signStr];
                    
                    [methodList addObject:methodDesc];
                }
                
            }
        }
        free(methods);
        
        typeDescriptor.classMethods = methodDict;
    }
    
    //导出父级方法
    LSCExportTypeDescriptor *parentTypeDescriptor = targetTypeDescriptor.parentTypeDescriptor;
    if (parentTypeDescriptor)
    {
        [self _exportsClassMethods:typeDescriptor
                        targetType:parentTypeDescriptor
                             state:state];
    }
}


/**
 导出类方法

 @param typeDescriptor 类型
 @param state Lua状态
 */
- (void)_exportsClassMethods:(LSCExportTypeDescriptor *)typeDescriptor
                       state:(lua_State *)state
{
    [self _exportsClassMethods:typeDescriptor
                    targetType:typeDescriptor
                         state:state];
}


/**
 导出属性

 @param typeDescriptor 类型
 @param state 状态
 
 @return 属性Selector名称集合，用于在导出方法时过滤属性的Getter和Setter
 */
- (NSArray<NSString *> *)_exportsProperties:(LSCExportTypeDescriptor *)typeDescriptor
                                      state:(lua_State *)state
{
    NSMutableSet<NSString *> *propertySelectorList = nil;
    if (typeDescriptor.nativeType != NULL)
    {
        propertySelectorList = [NSMutableSet set];
        
        NSMutableDictionary *propertiesDict = [NSMutableDictionary dictionary];
        
        //注册属性
        //先判断是否有注解排除实例方法
        NSArray *excludesPropertyNames = nil;
        if (class_conformsToProtocol(typeDescriptor.nativeType, @protocol(LSCExportTypeAnnotation)))
        {
            if ([self _declareClassMethodResponderToSelector:@selector(excludeProperties) withClass:typeDescriptor.nativeType])
            {
                excludesPropertyNames = [typeDescriptor.nativeType excludeProperties];
            }
        }
        
        uint count = 0;
        objc_property_t *properties = class_copyPropertyList(typeDescriptor.nativeType, &count);

        for (int i = 0; i < count; i++)
        {
            objc_property_t property = *(properties + i);
            NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
            
            //获取属性特性
            BOOL readonly = NO;
            NSString *getterName = nil;
            NSString *setterName = nil;
            uint attrCount = 0;
            objc_property_attribute_t *attrs = property_copyAttributeList(property, &attrCount);
            for (int j = 0; j < attrCount; j++)
            {
                objc_property_attribute_t attr = *(attrs + j);
                if (strcmp(attr.name, "G") == 0)
                {
                    getterName = [NSString stringWithUTF8String:attr.value];
                }
                else if (strcmp(attr.name, "S") == 0)
                {
                    //Setter
                    setterName = [NSString stringWithUTF8String:attr.value];
                }
                else if (strcmp(attr.name, "R") == 0)
                {
                    //只读属性
                    readonly = YES;
                }
            }
            free(attrs);
            
            if (!getterName)
            {
                getterName = propertyName;
            }
            if (!setterName)
            {
                setterName = [NSString stringWithFormat:@"set%@%@:",
                              [propertyName.capitalizedString substringToIndex:1],
                              [propertyName substringFromIndex:1]];
            }
            
            if (!readonly)
            {
                [propertySelectorList addObject:setterName];
            }
            [propertySelectorList addObject:getterName];
            
            if ([propertyName hasPrefix:@"_"]
                || [propertyName isEqualToString:@"hash"]
                || [propertyName isEqualToString:@"superclass"]
                || [propertyName isEqualToString:@"description"]
                || [propertyName isEqualToString:@"debugDescription"]
                || [excludesPropertyNames containsObject:propertyName])
            {
                continue;
            }
            
            //生成导出属性
            LSCExportPropertyDescriptor *propertyDescriptor = [[LSCExportPropertyDescriptor alloc] initWithName:propertyName getterSelector:NSSelectorFromString(getterName) setterSelector:readonly ? nil : NSSelectorFromString(setterName)];
            
            [propertiesDict setObject:propertyDescriptor forKey:propertyDescriptor.name];
        }
        
        free(properties);
        
        //记录属性Selector名称集合
        typeDescriptor.propertySelectorNames = propertySelectorList;
        //记录导出属性
        typeDescriptor.properties = propertiesDict;
        
        //加入所有父类属性名称集合，用于检测当前类型是否有重载父级属性
        LSCExportTypeDescriptor *parentTypeDescriptor = typeDescriptor.parentTypeDescriptor;
        while (parentTypeDescriptor)
        {
            [propertySelectorList addObjectsFromArray:parentTypeDescriptor.propertySelectorNames.allObjects];
            parentTypeDescriptor = parentTypeDescriptor.parentTypeDescriptor;
        }
    }
    
    return [propertySelectorList allObjects];
}

/**
 导出实例方法

 @param typeDescriptor 类型
 @param propertySelectorList 属性Getter／Setter列表
 @param state Lua状态
 */
- (void)_exportsInstanceMethods:(LSCExportTypeDescriptor *)typeDescriptor
           propertySelectorList:(NSArray<NSString *> *)propertySelectorList
                          state:(lua_State *)state
{
    if (typeDescriptor.nativeType != NULL)
    {
        //注册实例方法
        //先判断是否有注解排除实例方法
        NSArray *excludesMethodNames = nil;
        if (class_conformsToProtocol(typeDescriptor.nativeType, @protocol(LSCExportTypeAnnotation)))
        {
            if ([self _declareClassMethodResponderToSelector:@selector(excludeExportInstanceMethods) withClass:typeDescriptor.nativeType])
            {
                excludesMethodNames = [typeDescriptor.nativeType excludeExportInstanceMethods];
            }
        }
        
        NSArray *buildInExcludeMethodNames = @[];
        
        //解析方法
        NSMutableDictionary *methodDict = [typeDescriptor.instanceMethods mutableCopy];
        if (!methodDict)
        {
            methodDict = [NSMutableDictionary dictionary];
        }
        
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(typeDescriptor.nativeType, &methodCount);
        for (const Method *m = methods; m < methods + methodCount; m ++)
        {
            SEL selector = method_getName(*m);
            
            NSString *methodName = NSStringFromSelector(selector);
            if (![methodName hasPrefix:@"_"]
                && ![methodName hasPrefix:@"."]
                && ![methodName hasPrefix:@"init"]
                && ![methodName isEqualToString:@"dealloc"]
                && ![buildInExcludeMethodNames containsObject:methodName]
                && ![propertySelectorList containsObject:methodName]
                && ![excludesMethodNames containsObject:methodName])
            {
                NSString *luaMethodName = [self _getLuaMethodNameWithSelectorName:methodName];
                
                //判断是否已导出
                __block BOOL hasExists = NO;
                [LSCEngineAdapter getField:state index:-1 name:luaMethodName.UTF8String];
                if (![LSCEngineAdapter isNil:state index:-1])
                {
                    hasExists = YES;
                }
                [LSCEngineAdapter pop:state count:1];
                
                if (!hasExists)
                {
                    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
                    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
                    [LSCEngineAdapter pushString:luaMethodName.UTF8String state:state];
                    [LSCEngineAdapter pushCClosure:instanceMethodRouteHandler n:3 state:state];
                    
                    [LSCEngineAdapter setField:state index:-2 name:luaMethodName.UTF8String];
                }
                
                NSMutableArray<LSCExportMethodDescriptor *> *methodList = methodDict[luaMethodName];
                if (!methodList)
                {
                    methodList = [NSMutableArray array];
                    [methodDict setObject:methodList forKey:luaMethodName];
                }
                
                //获取方法签名
                NSString *signStr = [self _getMethodSign:*m];
                
                hasExists = NO;
                [methodList enumerateObjectsUsingBlock:^(LSCExportMethodDescriptor * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    
                    if ([obj.paramsSignature isEqualToString:signStr])
                    {
                        hasExists = YES;
                        *stop = YES;
                    }
                    
                }];
                
                if (!hasExists)
                {
                    NSMethodSignature *sign = [typeDescriptor.nativeType instanceMethodSignatureForSelector:selector];
                    LSCExportMethodDescriptor *methodDesc = [[LSCExportMethodDescriptor alloc] initWithSelector:selector methodSignature:sign paramsSignature:signStr];

                    [methodList addObject:methodDesc];
                }
            }
        }
        free(methods);
        
        typeDescriptor.instanceMethods = methodDict;
    }
}

/**
 根据Selector名称获取Lua中的方法名称

 @param selectorName Selector名称
 @return Lua中的方法名
 */
- (NSString *)_getLuaMethodNameWithSelectorName:(NSString *)selectorName
{
    NSString *luaName = selectorName;
    
    NSRange range = [luaName rangeOfString:@":"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"With"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"At"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    range = [luaName rangeOfString:@"By"];
    if (range.location != NSNotFound)
    {
        luaName = [luaName substringToIndex:range.location];
    }
    
    return luaName;
}

/**
 获取类型名称

 @param cls 类型
 @return 名称
 */
- (NSString *)_typeNameWithClass:(Class<LSCExportType>)cls
{
    NSString *name = nil;
    
    //先判断类型是否有进行注解，注：此处必须使用class_conformsToProtocol方法判断，可以具体到指定类型是否实现协议
    //如果使用conformsToProtocol的objc方法则会检测父类是否使用协议，不符合注解规则
    if (class_conformsToProtocol(cls, @protocol(LSCExportTypeAnnotation)))
    {
        if ([self _declareClassMethodResponderToSelector:@selector(typeName) withClass:cls])
        {
            //当前方法实现为
            name = [(id<LSCExportTypeAnnotation>)cls typeName];
        }
    }
    
    if (!name)
    {
        //将类型名称转换为模块名称
        NSString *clsName = NSStringFromClass(cls);
        //Fixed : 由于Swift中类名带有模块名称，因此需要根据.分割字符串，并取最后一部份为导出类名
        NSArray<NSString *> *nameComponents = [clsName componentsSeparatedByString:@"."];
        name = nameComponents.lastObject;
    }
    
    return name;
}

/**
 创建原生对象实例
 
 @param object 类型实例对象
 @param typeDescriptor 类型
 */
- (void)_initLuaObjectWithObject:(id)object type:(LSCExportTypeDescriptor *)typeDescriptor;
{
    lua_State *state = self.context.currentSession.state;
    int errFuncIndex = [self.context catchLuaException];
    
    [self _attachLuaInstanceWithNativeObject:object type:typeDescriptor];
    
    //通过_createLuaInstanceWithState方法后会创建实例并放入栈顶
    //调用实例对象的init方法
    [LSCEngineAdapter getField:state index:-1 name:"init"];
    if ([LSCEngineAdapter isFunction:state index:-1])
    {
        [LSCEngineAdapter pushValue:-2 state:state];
        
        //将create传入的参数传递给init方法
        //-4 代表有4个非参数值在栈中，由栈顶开始计算，分别是：实例对象，init方法，实例对象，异常捕获方法
        int paramCount = [LSCEngineAdapter getTop:state] - 4;
        for (int i = 1; i <= paramCount; i++)
        {
            [LSCEngineAdapter pushValue:i state:state];
        }
        
        [LSCEngineAdapter pCall:state nargs:paramCount + 1 nresults:0 errfunc:errFuncIndex];
    }
    else
    {
        [LSCEngineAdapter pop:state count:1];       //出栈init方法
    }
    
    //移除异常捕获方法
    [LSCEngineAdapter remove:state index:errFuncIndex];
}

/**
 将一个原生对象附加到Lua对象中
 
 @param nativeObject 原生实例对象
 @param typeDescriptor 类型描述
 */
- (void)_attachLuaInstanceWithNativeObject:(id)nativeObject
                                      type:(LSCExportTypeDescriptor *)typeDescriptor
{
    lua_State *state = self.context.currentSession.state;
    
    //先为实例对象在lua中创建内存
    LSCUserdataRef ref = (LSCUserdataRef)[LSCEngineAdapter newUserdata:state size:sizeof(LSCUserdataRef)];
    if (nativeObject)
    {
        //创建本地实例对象，赋予lua的内存块并进行保留引用
        ref -> value = (void *)CFBridgingRetain(nativeObject);
    }
    
    //创建一个临时table作为元表，用于在lua上动态添加属性或方法
    [LSCEngineAdapter newTable:state];
    
    ///变更索引为function，实现动态路由
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)nativeObject state:state];
    [LSCEngineAdapter pushCClosure:instanceIndexHandler n:3 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__index"];
    
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)typeDescriptor state:state];
    [LSCEngineAdapter pushLightUserdata:(__bridge void *)nativeObject state:state];
    [LSCEngineAdapter pushCClosure:instanceNewIndexHandler n:3 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__newindex"];

    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushCClosure:objectDestroyHandler n:1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__gc"];

    [LSCEngineAdapter pushLightUserdata:(__bridge void *)self state:state];
    [LSCEngineAdapter pushCClosure:objectToStringHandler n:1 state:state];
    [LSCEngineAdapter setField:state index:-2 name:"__tostring"];
    
    [LSCEngineAdapter pushValue:-1 state:state];
    [LSCEngineAdapter setMetatable:state index:-3];
    
    [LSCEngineAdapter getMetatable:state name:typeDescriptor.prototypeTypeName.UTF8String];
    if ([LSCEngineAdapter isTable:state index:-1])
    {
        [LSCEngineAdapter setMetatable:state index:-2];
    }
    else
    {
        [LSCEngineAdapter pop:state count:1];
    }
    
    [LSCEngineAdapter pop:state count:1];
    
    //将创建对象放入到_vars_表中，主要修复对象创建后，在init中调用方法或者访问属性，由于对象尚未记录在_vars_中，而循环创建lua对象，并导致栈溢出。
    NSString *objectId = [NSString stringWithFormat:@"%p", nativeObject];
    [self.context.dataExchanger setLubObjectByStackIndex:-1 objectId:objectId];
}

/**
 查找父级类型描述

 @param typeDescriptor 类型描述
 @return 类型描述
 */
- (LSCExportTypeDescriptor *)_findParentTypeDescriptorWithTypeDescriptor:(LSCExportTypeDescriptor *)typeDescriptor
{
    if (typeDescriptor.nativeType == nil)
    {
        //如果为Object或者lua定义类型，则直接返回空
        //注：lua定义类型不会走这个方法，并且在创建类型时已经指定父类
        return nil;
    }
    
    Class parentType = class_getSuperclass(typeDescriptor.nativeType);
    NSString *parentTypeName = self.exportTypesMapping[NSStringFromClass(parentType)];
    LSCExportTypeDescriptor *parentTypeDescriptor = self.exportTypes[parentTypeName];
    
    if (!parentTypeDescriptor)
    {
        parentTypeDescriptor = self.exportTypes[@"Object"];
    }
    
    //关联关系
    typeDescriptor.parentTypeDescriptor = parentTypeDescriptor;
    
    return parentTypeDescriptor;
}

/**
 返回对象在Lua中的类型描述

 @param object 对象实例
 @return 类型描述，如果为nil则表示非导出类型
 */
- (LSCExportTypeDescriptor *)_typeDescriptorWithObject:(id)object
{
    if ([object conformsToProtocol:@protocol(LSCExportType)])
    {
        NSString *clsName = NSStringFromClass([object class]);
        NSString *typeName = self.exportTypesMapping[clsName];
        return self.exportTypes[typeName];
    }
    else if ([object isKindOfClass:[LSCVirtualInstance class]])
    {
        //为Lua层类型
        return ((LSCVirtualInstance *)object).typeDescriptor;
    }
    
    return nil;
}

/**
 获取调用器

 @param methodName 方法名
 @param arguments 参数列表
 @param typeDesc 类型
 @param isStatic 是否为类方法
 @return 调用器对象
 */
- (NSInvocation *)_invocationWithMethodName:(NSString *)methodName
                                  arguments:(NSArray *)arguments
                                   typeDesc:(LSCExportTypeDescriptor *)typeDesc
                                   isStatic:(BOOL)isStatic
{
    LSCExportMethodDescriptor *methodDesc = nil;
    if (isStatic)
    {
        methodDesc = [typeDesc classMethodWithName:methodName arguments:arguments];
    }
    else
    {
        methodDesc = [typeDesc instanceMethodWithName:methodName arguments:arguments];
    }
    
    return [methodDesc createInvocation];
}


/**
 获取方法签名

 @param method 方法
 @return 签名字符串
 */
- (NSString *)_getMethodSign:(Method)method
{
    NSMutableString *signStr = [NSMutableString string];
    int argCount = method_getNumberOfArguments(method);
    for (int i = 2; i < argCount; i++)
    {
        char s[256] = {0};
        method_getArgumentType(method, i, s, 256);
        [signStr appendString:[NSString stringWithUTF8String:s]];
    }
    
    return signStr;
}


/**
 判断指定类型是否有定义指定类方法

 @param selector 方法名称
 @param class 类型
 @return YES 表示有实现， NO 表示没有
 */
- (BOOL)_declareClassMethodResponderToSelector:(SEL)selector withClass:(Class)class
{
    Class metaCls = objc_getMetaClass(NSStringFromClass(class).UTF8String);
    
    uint count = 0;
    Method *methodList = class_copyMethodList(metaCls, &count);
    for (int i = 0; i < count; i++)
    {
        if (method_getName(*(methodList + i)) == selector)
        {
            return YES;
        }
    }
    
    free(methodList);
    
    return NO;
}


/**
 查找实例导出属性描述

 @param session 会话
 @param typeDescriptor 类型描述
 @param propertyName 属性名称
 @return 属性描述对象
 */
- (LSCExportPropertyDescriptor *)_findInstancePropertyWithSession:(LSCSession *)session
                                                   typeDescriptor:(LSCExportTypeDescriptor *)typeDescriptor
                                                     propertyName:(NSString *)propertyName
{
    LSCExportPropertyDescriptor *propertyDescriptor = nil;
    lua_State *state = session.state;
    if (typeDescriptor)
    {
        [LSCEngineAdapter getMetatable:state name:typeDescriptor.prototypeTypeName.UTF8String];
        [LSCEngineAdapter pushString:propertyName.UTF8String state:state];
        [LSCEngineAdapter rawGet:state index:-2];
        
        if ([LSCEngineAdapter isNil:state index:-1])
        {
            //不存在
            propertyDescriptor = [typeDescriptor.properties objectForKey:propertyName];
            if (!propertyDescriptor)
            {
                if (typeDescriptor.parentTypeDescriptor)
                {
                    //递归父类
                    propertyDescriptor = [self _findInstancePropertyWithSession:session
                                                                 typeDescriptor:typeDescriptor.parentTypeDescriptor
                                                                   propertyName:propertyName];
                }
            }
        }
        
        [LSCEngineAdapter pop:state count:2];
    }
    
    return propertyDescriptor;
}

/**
 获取实例属性描述

 @param session 会话
 @param instance 实例对象
 @param typeDescriptor 类型描述
 @param propertyName 属性名称
 
 @return 返回值数量
 */
- (int)_instancePropertyWithSession:(LSCSession *)session
                           instance:(id)instance
                     typeDescriptor:(LSCExportTypeDescriptor *)typeDescriptor
                       propertyName:(NSString *)propertyName
{
    int retValueCount = 1;
    lua_State *state = session.state;
    if (typeDescriptor)
    {
        [LSCEngineAdapter getMetatable:state name:typeDescriptor.prototypeTypeName.UTF8String];
        [LSCEngineAdapter pushString:propertyName.UTF8String state:state];
        [LSCEngineAdapter rawGet:state index:-2];

        if ([LSCEngineAdapter isNil:state index:-1])
        {
            [LSCEngineAdapter pop:state count:2];
            
            //不存在
            LSCExportPropertyDescriptor *propertyDescriptor = [typeDescriptor.properties objectForKey:propertyName];
            if (!propertyDescriptor)
            {
                if (typeDescriptor.parentTypeDescriptor)
                {
                    //递归父类
                    retValueCount = [self _instancePropertyWithSession:session
                                                              instance:instance
                                                        typeDescriptor:typeDescriptor.parentTypeDescriptor
                                                          propertyName:propertyName];
                }
                else
                {
                    [LSCEngineAdapter pushNil:state];
                }
            }
            else
            {
                LSCValue *retValue = [propertyDescriptor invokeGetterWithInstance:instance
                                                                   typeDescriptor:typeDescriptor];
                retValueCount = [session setReturnValue:retValue];
            }
        }
        
        [LSCEngineAdapter remove:state index:-1-retValueCount];
    }
    
    return retValueCount;
}

#pragma mark - C Method

/**
 类方法路由处理器

 @param state 状态
 @return 返回参数数量
 */
static int classMethodRouteHandler(lua_State *state)
{
    int retCount = 0;
    
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    index = [LSCEngineAdapter upvalueIndex:2];
    ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportTypeDescriptor *typeDescriptor = (__bridge LSCExportTypeDescriptor *)ptr;
    
    index = [LSCEngineAdapter upvalueIndex:3];
    const char *methodNameCStr = [LSCEngineAdapter toString:state index:index];
    NSString *methodName = [NSString stringWithUTF8String:methodNameCStr];
    
    LSCSession *callSession = [exporter.context makeSessionWithState:state];
    NSArray *arguments = [callSession parseArguments];
    
    //筛选方法，对于重载方法需要根据lua传入参数进行筛选
    NSInvocation *invocation = [exporter _invocationWithMethodName:methodName
                                                         arguments:arguments
                                                          typeDesc:typeDescriptor
                                                          isStatic:YES];

    //确定调用方法的Target
    if (invocation)
    {
        LSCValue *retValue = [typeDescriptor _invokeMethodWithInstance:nil
                                                            invocation:invocation
                                                             arguments:arguments];
        
        if (retValue)
        {
            retCount = [callSession setReturnValue:retValue];
        }
    }
    else
    {
        NSString *errMsg = [NSString stringWithFormat:@"call `%@` method fail : argument type mismatch", methodName];
        [LSCEngineAdapter error:state message:errMsg.UTF8String];
    }
    
    [exporter.context destroySession:callSession];
    
    return retCount;
}


/**
 实例方法路由处理

 @param state 状态
 @return 参数个数
 */
static int instanceMethodRouteHandler(lua_State *state)
{
    int retCount = 0;

    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;

    index = [LSCEngineAdapter upvalueIndex:2];
    ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportTypeDescriptor *typeDescriptor = (__bridge LSCExportTypeDescriptor *)ptr;

    index = [LSCEngineAdapter upvalueIndex:3];
    const char *methodNameCStr = [LSCEngineAdapter toString:state index:index];
    NSString *methodName = [NSString stringWithUTF8String:methodNameCStr];

    if ([LSCEngineAdapter type:state index:1] != LUA_TUSERDATA)
    {
        NSString *errMsg = [NSString stringWithFormat:@"call %@ method error : missing self parameter, please call by instance:methodName(param)", methodName];
        [LSCEngineAdapter error:state message:errMsg.UTF8String];
        return retCount;
    }

    //创建调用会话
    LSCSession *callSession = [exporter.context makeSessionWithState:state];
    NSArray *arguments = [callSession parseArguments];
    id instance = [arguments[0] toObject];

    NSInvocation *invocation = [exporter _invocationWithMethodName:methodName
                                                         arguments:arguments
                                                          typeDesc:typeDescriptor
                                                          isStatic:NO];

    //获取类实例对象
    if (invocation && instance)
    {
        LSCValue *retValue = [typeDescriptor _invokeMethodWithInstance:instance
                                                            invocation:invocation
                                                             arguments:arguments];

        if (retValue)
        {
            retCount = [callSession setReturnValue:retValue];
        }
    }
    else
    {
        NSString *errMsg = [NSString stringWithFormat:@"call `%@` method fail : argument type mismatch", methodName];
        [LSCEngineAdapter error:state message:errMsg.UTF8String];
    }

    [exporter.context destroySession:callSession];
    
    return retCount;
}

/**
 *  创建对象时处理
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int objectCreateHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    index = [LSCEngineAdapter upvalueIndex:2];
    ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportTypeDescriptor *typeDescriptor = (__bridge LSCExportTypeDescriptor *)ptr;
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //创建对象
    id instance = nil;
    if (typeDescriptor.nativeType != NULL)
    {
        instance = [[typeDescriptor.nativeType alloc] init];
    }
    else
    {
        //创建一个虚拟的类型对象
        instance = [[LSCVirtualInstance alloc] initWithTypeDescriptor:typeDescriptor];
    }
    
    [exporter _initLuaObjectWithObject:instance type:typeDescriptor];
    
    [exporter.context destroySession:session];
    
    return 1;
}

/**
 实例对象更新索引处理
 
 @param state 状态机
 @return 参数数量
 */
static int instanceNewIndexHandler (lua_State *state)
{
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)[LSCEngineAdapter toPointer:state
                                                                                  index:[LSCEngineAdapter upvalueIndex:1]];
    LSCExportTypeDescriptor *typeDescriptor = (LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:2]];
    id instance = (__bridge id)[LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:3]];
    NSString *key = [NSString stringWithUTF8String:[LSCEngineAdapter toString:state index:2]];
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //检测是否存在类型属性
    LSCExportPropertyDescriptor *propertyDescriptor = [exporter _findInstancePropertyWithSession:session
                                                                                  typeDescriptor:typeDescriptor
                                                                                    propertyName:key];
    if (propertyDescriptor)
    {
        LSCValue *value = [LSCValue tmpValueWithContext:exporter.context atIndex:3];
        [propertyDescriptor invokeSetterWithInstance:instance typeDescriptor:typeDescriptor value:value];
    }
    else
    {
        //先找到实例对象的元表，向元表添加属性
        [LSCEngineAdapter getMetatable:state index:1];
        if ([LSCEngineAdapter isTable:state index:-1])
        {
            [LSCEngineAdapter pushValue:2 state:state];
            [LSCEngineAdapter pushValue:3 state:state];
            [LSCEngineAdapter rawSet:state index:-3];
        }
    }
    
    [exporter.context destroySession:session];
    
    return 0;
}

/**
 实例对象索引方法处理器
 
 @param state 状态
 @return 返回参数数量
 */
static int instanceIndexHandler(lua_State *state)
{
    int retValueCount = 1;
    
    LSCExportsTypeManager *exporter = (LSCExportsTypeManager *)[LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:1]];
    LSCExportTypeDescriptor *typeDescriptor = (LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:2]];
    id instance = (__bridge id)[LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:3]];
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    NSString *key = [NSString stringWithUTF8String:[LSCEngineAdapter toString:state index:2]];
    
    //检测元表是否包含指定值
    [LSCEngineAdapter getMetatable:state index:1];
    [LSCEngineAdapter pushValue:2 state:state];
    [LSCEngineAdapter rawGet:state index:-2];

    if ([LSCEngineAdapter isNil:state index:-1])
    {
        [LSCEngineAdapter pop:state count:1];
        
        retValueCount = [exporter _instancePropertyWithSession:session
                                                      instance:instance
                                                typeDescriptor:typeDescriptor
                                                  propertyName:key];
    }
    
    [exporter.context destroySession:session];
    
    return retValueCount;
}

/**
 *  对象销毁处理
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int objectDestroyHandler (lua_State *state)
{
    if ([LSCEngineAdapter getTop:state] > 0 && [LSCEngineAdapter isUserdata:state index:1])
    {
        int index = [LSCEngineAdapter upvalueIndex:1];
        const void *ptr = [LSCEngineAdapter toPointer:state index:index];
        LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
        
        LSCSession *session = [exporter.context makeSessionWithState:state];
        
        //如果为userdata类型，则进行释放
        LSCUserdataRef ref = (LSCUserdataRef)[LSCEngineAdapter toUserdata:state index:1];
        
        int errFuncIndex = [exporter.context catchLuaException];
        
        [LSCEngineAdapter pushValue:1 state:state];
        [LSCEngineAdapter getField:state index:-1 name:"destroy"];
        if ([LSCEngineAdapter isFunction:state index:-1])
        {
            [LSCEngineAdapter pushValue:1 state:state];
            [LSCEngineAdapter pCall:state nargs:1 nresults:0 errfunc:errFuncIndex];
            [LSCEngineAdapter pop:state count:1];
        }
        else
        {
            [LSCEngineAdapter pop:state count:2]; //出栈方法、实例对象
        }
        
        //移除异常捕获方法
        [LSCEngineAdapter remove:state index:errFuncIndex];
        
        //释放内存
        CFBridgingRelease(ref -> value);
        
        [exporter.context destroySession:session];
    }
    
    return 0;
}


/**
 类型转换为字符串处理

 @param state 状态
 @return 参数数量
 */
static int classToStringHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    LSCExportTypeDescriptor *typeDescriptor = nil;
    
    [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
    if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
    {
        typeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
    }
    
    if (typeDescriptor)
    {
        [LSCEngineAdapter pushString:[[NSString stringWithFormat:@"[%@ type]", typeDescriptor.typeName] UTF8String] state:state];
    }
    else
    {
        [LSCEngineAdapter error:state message:"Can not describe unknown type."];
        [LSCEngineAdapter pushNil:state];
    }
    
    [exporter.context destroySession:session];
    
    return 1;
}

/**
 转换Prototype为字符串处理

 @param state 状态
 @return 参数数量
 */
static int prototypeToStringHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    LSCExportTypeDescriptor *typeDescriptor = nil;
    
    [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
    if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
    {
        typeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
    }
    
    if (typeDescriptor)
    {
        [LSCEngineAdapter pushString:[[NSString stringWithFormat:@"[%@ prototype]", typeDescriptor.typeName] UTF8String] state:state];
    }
    else
    {
        [LSCEngineAdapter error:state message:"Can not describe unknown prototype."];
        [LSCEngineAdapter pushNil:state];
    }
    
    [exporter.context destroySession:session];
    
    return 1;
}

/**
 设置原型的新属性处理

 @param state 状态
 @return 参数数量
 */
static int prototypeNewIndexHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //t,k,v
    BOOL isPropertyReg = NO;
    if ([LSCEngineAdapter type:state index:3] == LUA_TTABLE)
    {
        //检测是否为属性设置
        LSCFunction *getter = nil;
        LSCFunction *setter = nil;
        
        [LSCEngineAdapter getField:state index:3 name:"get"];
        if ([LSCEngineAdapter type:state index:-1] == LUA_TFUNCTION)
        {
            LSCValue *getterValue = [LSCValue valueWithContext:exporter.context atIndex:-1];
            getter = [getterValue toFunction];
        }
        
        [LSCEngineAdapter pop:state count:1];
        
        [LSCEngineAdapter getField:state index:3 name:"set"];
        if ([LSCEngineAdapter type:state index:-1] == LUA_TFUNCTION)
        {
            LSCValue *setterValue = [LSCValue valueWithContext:exporter.context atIndex:-1];
            setter = [setterValue toFunction];
        }
        
        [LSCEngineAdapter pop:state count:1];
        
        if (getter || setter)
        {
            isPropertyReg = YES;
            
            //注册属性
            [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
            if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
            {
                LSCExportTypeDescriptor *typeDescriptor = (LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
                
                LSCValue *propertyNameValue = [LSCValue valueWithContext:exporter.context atIndex:2];
                LSCExportPropertyDescriptor *propertyDescriptor = [[LSCExportPropertyDescriptor alloc] initWithName:[propertyNameValue toString] getterFunction:getter setterFunction:setter];
                
                NSMutableDictionary *properties = [typeDescriptor.properties mutableCopy];
                if (!typeDescriptor.properties)
                {
                    properties = [NSMutableDictionary dictionary];
                }
                [properties setObject:propertyDescriptor forKey:propertyDescriptor.name];
                typeDescriptor.properties = properties;
            }
        }
    }
    
    if (!isPropertyReg)
    {
        //直接设置
        [LSCEngineAdapter rawSet:state index:1];
    }
    
    [exporter.context destroySession:session];
    
    return 0;
}

/**
 *  对象转换为字符串处理
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int objectToStringHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    LSCExportTypeDescriptor *typeDescriptor = nil;
    
    [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
    if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
    {
        typeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
    }
    
    if (typeDescriptor)
    {
        NSString *desc = [NSString stringWithFormat:@"[%@ object<%p>]",
                          typeDescriptor.typeName, [LSCEngineAdapter toPointer:state index:1]];
        [LSCEngineAdapter pushString:[desc UTF8String] state:state];
    }
    else
    {
        [LSCEngineAdapter error:state message:"Can not describe unknown object."];
        [LSCEngineAdapter pushNil:state];
    }
    
    [exporter.context destroySession:session];
    
    return 1;
}

/**
 *  子类化
 *
 *  @param state 状态机
 *
 *  @return 参数数量
 */
static int subClassHandler (lua_State *state)
{
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    index = [LSCEngineAdapter upvalueIndex:2];
    ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportTypeDescriptor *typeDescriptor = (__bridge LSCExportTypeDescriptor *)ptr;
    
    if ([LSCEngineAdapter getTop:state] == 0)
    {
        [LSCEngineAdapter error:state message:"Miss the subclass name parameter"];
        return 0;
    }
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //构建子类型描述
    NSString *typeName = [NSString stringWithUTF8String:[LSCEngineAdapter checkString:state index:1]];
    LSCExportTypeDescriptor *subTypeDescriptor = [[LSCExportTypeDescriptor alloc] initWithTypeName:typeName nativeType:typeDescriptor.nativeType];
    subTypeDescriptor.parentTypeDescriptor = typeDescriptor;
    [exporter.exportTypes setObject:subTypeDescriptor forKey:subTypeDescriptor.typeName];
    
    [exporter _exportsType:subTypeDescriptor state:state];
    
    [exporter.context destroySession:session];
    
    return 0;
}

/**
 判断是否是该类型的子类
 
 @param state 状态机
 @return 参数数量
 */
static int subclassOfHandler (lua_State *state)
{
    if ([LSCEngineAdapter getTop:state] == 0)
    {
        [LSCEngineAdapter pushBoolean:NO state:state];
        return 1;
    }
    
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;
    
    index = [LSCEngineAdapter upvalueIndex:2];
    ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportTypeDescriptor *typeDescriptor = (__bridge LSCExportTypeDescriptor *)ptr;
    
    BOOL flag = NO;
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    if ([LSCEngineAdapter type:state index:1] == LUA_TTABLE)
    {
        [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
        if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
        {
            LSCExportTypeDescriptor *checkTypeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
            flag = [typeDescriptor subtypeOfType:checkTypeDescriptor];
        }
    }
    
    [LSCEngineAdapter pushBoolean:flag state:state];
    
    [exporter.context destroySession:session];
    
    return 1;
}

/**
 判断是否是该类型的实例对象
 
 @param state 状态机
 @return 参数数量
 */
static int instanceOfHandler (lua_State *state)
{
    if ([LSCEngineAdapter getTop:state] < 2)
    {
        [LSCEngineAdapter pushBoolean:NO state:state];
        return 1;
    }
    
    int index = [LSCEngineAdapter upvalueIndex:1];
    const void *ptr = [LSCEngineAdapter toPointer:state index:index];
    LSCExportsTypeManager *exporter = (__bridge LSCExportsTypeManager *)ptr;

    BOOL flag = NO;
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //获取实例类型
    LSCExportTypeDescriptor *typeDescriptor = nil;
    [LSCEngineAdapter getField:state index:1 name:"_nativeType"];
    if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
    {
        typeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
    }
    [LSCEngineAdapter pop:state count:1];
    
    if (typeDescriptor)
    {
        if ([LSCEngineAdapter type:state index:2] == LUA_TTABLE)
        {
            [LSCEngineAdapter getField:state index:2 name:"_nativeType"];
            if ([LSCEngineAdapter type:state index:-1] == LUA_TLIGHTUSERDATA)
            {
                LSCExportTypeDescriptor *checkTypeDescriptor = (__bridge LSCExportTypeDescriptor *)[LSCEngineAdapter toPointer:state index:-1];
                flag = [typeDescriptor subtypeOfType:checkTypeDescriptor];
            }
        }
    }
    
    
    [LSCEngineAdapter pushBoolean:flag state:state];
    
    [exporter.context destroySession:session];

    return 1;
}

/**
 全局对象的index元方法处理

 @param state 状态
 @return 返回参数数量
 */
static int globalIndexMetaMethodHandler(lua_State *state)
{
    LSCExportsTypeManager *exporter = [LSCEngineAdapter toPointer:state index:[LSCEngineAdapter upvalueIndex:1]];
    
    LSCSession *session = [exporter.context makeSessionWithState:state];
    
    //获取key
    NSString *key = [NSString stringWithUTF8String:[LSCEngineAdapter toString:state index:2]];
    
    [LSCEngineAdapter rawGet:state index:1];
    if ([LSCEngineAdapter isNil:state index:-1])
    {
        //检测是否该key是否为导出类型
        LSCExportTypeDescriptor *typeDescriptor = exporter.exportTypes[key];
        if (typeDescriptor)
        {
            //为导出类型
            [LSCEngineAdapter pop:state count:1];
            
            [exporter _prepareExportsTypeWithDescriptor:typeDescriptor];
            
            //重新获取
            [LSCEngineAdapter pushString:key.UTF8String state:state];
            [LSCEngineAdapter rawGet:state index:1];
        }
    }
    
    [exporter.context destroySession:session];
    
    return 1;
}

@end
