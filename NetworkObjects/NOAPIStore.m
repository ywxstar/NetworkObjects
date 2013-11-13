//
//  NOAPIStore.m
//  NetworkObjects
//
//  Created by Alsey Coleman Miller on 10/21/13.
//  Copyright (c) 2013 CDA. All rights reserved.
//

#import "NOAPIStore.h"
#import "NOResourceProtocol.h"
#import "NetworkObjectsConstants.h"
#import "NOAPI.h"

@implementation NOAPIStore

+(void)initialize
{
    [NSPersistentStoreCoordinator registerStoreClass:[self class]
                                        forStoreType:[[self class] type]];
}

+(NSString *)type
{
    return NSStringFromClass([self class]);
}

-(id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                      configurationName:(NSString *)name
                                    URL:(NSURL *)url
                                options:(NSDictionary *)options
{
    self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options];
    if (self) {
        
        _cache = [[NSMutableDictionary alloc] init];
        
        _managedObjectIDs = [[NSMutableDictionary alloc] init];
        
        _versionCount = 0;
        
    }
    return self;
}

-(BOOL)loadMetadata:(NSError *__autoreleasing *)error
{
    NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
    [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString]
                       forKey:NSStoreUUIDKey];
    
    [mutableMetadata setValue:[[self class] type]
                       forKey:NSStoreTypeKey];
    
    [self setMetadata:mutableMetadata];
    
    return YES;
}

-(id)executeRequest:(NSPersistentStoreRequest *)request
        withContext:(NSManagedObjectContext *)context
              error:(NSError *__autoreleasing *)error
{
    // check that API is not null
    
    if (!self.api) {
        
        [NSException raise:NSInternalInconsistencyException
                    format:@"NOAPI property must not be nil"];
    }
    
    if (request.requestType == NSSaveRequestType) {
        
        NSSaveChangesRequest *saveRequest = (NSSaveChangesRequest *)request;
        
        return [self executeSaveRequest:saveRequest
                            withContext:context
                                  error:error];
    }
    
    NSFetchRequest *fetchRequest = (NSFetchRequest *)request;
    
    return [self executeFetchRequest:fetchRequest
                         withContext:context
                               error:error];
}

#pragma mark - Obtain Object ID

-(NSManagedObjectID *)managedObjectIDForResourceID:(NSNumber *)resourceID
                                            entity:(NSEntityDescription *)entity
{
    // Creates the object ID if it doesnt have one already
    NSMutableDictionary *entityIDs = _managedObjectIDs[entity.name];
    
    if (!entityIDs) {
        
        // validate that the given entity belongs to our store
        if (self.persistentStoreCoordinator.managedObjectModel.entitiesByName[entity.name] != entity) {
            
            [NSException raise:NSInvalidArgumentException
                        format:@"The entity was not found in the NOAPIStore's NSManagedObjectModel"];
        }
        
        entityIDs = [[NSMutableDictionary alloc] init];
        
        [_managedObjectIDs setObject:entityIDs
                             forKey:entity.name];
    }
    
    NSManagedObjectID *objectID = entityIDs[resourceID];
    
    if (!objectID) {
        
        objectID = [self newObjectIDForEntity:entity
                              referenceObject:resourceID];
        
        [entityIDs setObject:objectID
                     forKey:resourceID];
    }
    
    return objectID;
}

-(NSNumber *)resourceIDForManagedObjectID:(NSManagedObjectID *)objectID
{
    return [self referenceObjectForObjectID:objectID];
}

#pragma mark - Fetching

-(id)executeFetchRequest:(NSFetchRequest *)request
             withContext:(NSManagedObjectContext *)context
                   error:(NSError *__autoreleasing *)error
{
    NSAssert(request, @"NSFetchRequest must not be nil");
    
    // validate that the entity conforms to NOResourceKeysProtocol
    
    NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
    
    // get entity
    NSEntityDescription *entity = model.entitiesByName[request.entityName];
    
    if (!entity) {
        
        if ([model.entities containsObject:request.entity]) {
            
            entity = request.entity;
        }
    }
    
    // entity is nil
    
    if (!entity) {
        
        [NSException raise:NSInvalidArgumentException
                    format:@"NSFetchRequest doesn't specify a entity"];
    }
    
    // verify that it conforms to protocol
    
    Class entityClass = NSClassFromString(entity.managedObjectClassName);
    
    if (![entityClass conformsToProtocol:@protocol(NOResourceKeysProtocol)]) {
        
        [NSException raise:NSInternalInconsistencyException
                    format:@"%@ does not conform to NOResourceProtocol", entity.name];
    }
    
    // incremental store is only capable of fetching single results...
    
    // must specify resourceID...
    
    NSString *resourceIDKey = [entityClass resourceIDKey];
    
    // parse predicate (must include 'resourceID == x')
    
    NSString *predicate = request.predicate.predicateFormat;
    
    NSRegularExpression *exp = [NSRegularExpression regularExpressionWithPattern:@"(\S+) == (\S+)" options:NSRegularExpressionAllowCommentsAndWhitespace error:nil];
    
    NSArray *matches = [exp matchesInString:predicate
                                    options:NSMatchingAnchored
                                      range:NSRangeFromString(predicate)];
    
    NSString *resourceIDString;
    
    for (NSTextCheckingResult *result in matches) {
        
        // make sure one of the captured groups is the resource ID key
        
        NSString *capture1 = [predicate substringWithRange:[result rangeAtIndex:1]];
        
        NSString *capture2 = [predicate substringWithRange:[result rangeAtIndex:2]];
        
        NSString *resourceIDString;
        
        if ([capture1 isEqualToString:resourceIDKey]) {
            
            resourceIDString = capture2;
        }
        else {
            
            if ([capture2 isEqualToString:resourceIDKey]) {
                
                resourceIDString = capture1;
            }
        }
        
        // one of the captures is the resource ID key
        if (resourceIDString) {
            
            // verify it is a number
            
            NSRegularExpression *numberCheck = [NSRegularExpression regularExpressionWithPattern:@"\d+" options:NSRegularExpressionAllowCommentsAndWhitespace error:nil];
            
            NSArray *numberMatches = [numberCheck matchesInString:resourceIDString
                                                          options:NSMatchingAnchored
                                                            range:NSRangeFromString(resourceIDString)];
            
            if (numberMatches.count == 1) {
                
                // seem to have found the resourceID value
                
                NSTextCheckingResult *numberResult = numberMatches.firstObject;
                
                NSString *foundResourceID = [resourceIDString substringWithRange:numberResult.range];
                
                // conflicting resource IDs
                if (resourceIDString &&
                    resourceIDString.integerValue != foundResourceID.integerValue) {
                    
                    NSString *description = NSLocalizedString(@"Invalid predicate",
                                                              @"Invalid predicate");
                    
                    NSString *reason = NSLocalizedString(@"Conflicting resource IDs specified in predicate",
                                                         @"Conflicting resource IDs specified in predicate");
                    
                    *error = [NSError errorWithDomain:NetworkObjectsErrorDomain
                                                 code:NSPersistentStoreUnsupportedRequestTypeError
                                             userInfo:@{NSLocalizedDescriptionKey: description,
                                                        NSLocalizedFailureReasonErrorKey: reason}];
                    
                    return nil;
                }
            }
        }
    }
    
    // resource ID not specified in predicate
    if (!resourceIDString) {
        
        NSString *description = NSLocalizedString(@"Invalid predicate",
                                                  @"Invalid predicate");
        
        NSString *reason = NSLocalizedString(@"Predicate must always specify what resource ID to fetch",
                                             @"Predicate must always specify what resource ID to fetch");
        
        *error = [NSError errorWithDomain:NetworkObjectsErrorDomain
                                     code:NSPersistentStoreUnsupportedRequestTypeError
                                 userInfo:@{NSLocalizedDescriptionKey: description,
                                            NSLocalizedFailureReasonErrorKey: reason}];
        
        return nil;
    }
    
    NSUInteger resourceID = resourceIDString.integerValue;
    
    __block NSDictionary *resourceDict;
    
    // GCD
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    
    [self.api getResource:entity.name withID:resourceID completion:^(NSError *getError, NSDictionary *resource)
    {
        if (getError) {
            
            // dont forward error if resource was not found
            if (getError.code == NOAPINotFoundErrorCode) {
                
                resourceDict = nil;
                
                return;
            }
            
            // forward error
            *error = getError;
            return;
        }
        
        resourceDict = resource;
        
        dispatch_group_leave(group);
    }];
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    NSArray *dictionaryResults;
    
    // resource found
    if (resourceDict) {
        
        // add to cache...
        NSMutableDictionary *entityCache = _cache[entity.name];
        
        // first entity to be caches
        if (!entityCache) {
            
            entityCache = [[NSMutableDictionary alloc] init];
            
            [_cache setObject:entityCache
                       forKey:entity.name];
        }
        
        [entityCache setObject:resourceDict
                        forKey:[NSNumber numberWithInteger:resourceID]];
        
        // further filter object
        dictionaryResults = [@[resourceDict] filteredArrayUsingPredicate:request.predicate];
        
        // apply sort descriptors
        dictionaryResults = [dictionaryResults sortedArrayUsingDescriptors:request.sortDescriptors];
    }
    
    // return result as requested in resultType...
    
    if (request.resultType == NSCountResultType) {
        
        return @[[NSNumber numberWithInteger:dictionaryResults.count]];;
    }
    
    if (request.resultType == NSDictionaryResultType) {
        
        return dictionaryResults;
    }
    
    // get object IDs
    
    NSMutableArray *objectIDs = [[NSMutableArray alloc] init];
    
    for (NSDictionary *resourceDictionary in dictionaryResults) {
        
        NSNumber *resourceIDReference = resourceDict[resourceIDKey];
        
        NSManagedObjectID *objectID = [self managedObjectIDForResourceID:resourceIDReference
                                                                  entity:entity];
        
        [objectIDs addObject:objectID];
    }
    
    if (request.resultType == NSManagedObjectIDResultType) {
        
        return objectIDs;
    }
    
    // return faults (resultType == NSManagedObjectIDResultType)
    
    NSMutableArray *faults = [[NSMutableArray alloc] init];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        
        // get fault
        NSManagedObject *fault = [context objectWithID:objectID];
        
        [faults addObject:fault];
    }
    
    return faults;
}

-(NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                        withContext:(NSManagedObjectContext *)context
                                              error:(NSError *__autoreleasing *)error
{
    NSNumber *resourceID = [self referenceObjectForObjectID:objectID];
    
    NSMutableDictionary *entityCache = _cache[objectID.entity.name];
    
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithDictionary:entityCache[resourceID]];
    
    // Convert raw unique identifiers for to-one relationships into NSManagedObjectID instances
    
    for (NSRelationshipDescription *relationship in objectID.entity.relationshipsByName) {
        
        // to-one relationship
        if (!relationship.isToMany) {
            
            NSString *key = relationship.name;
            
            NSNumber *destinationResourceID = values[key];
            
            NSManagedObjectID *destinationObjectID = [self managedObjectIDForResourceID:destinationResourceID entity:relationship.destinationEntity];
            
            // replace destination resourceIDs with objectIDs in values dictionary
            [values setObject:destinationObjectID
                       forKey:key];
        }
    }
    
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID
                                                                         withValues:values
                                                                            version:_versionCount];
    
    return node;
}

-(id)newValueForRelationship:(NSRelationshipDescription *)relationship
             forObjectWithID:(NSManagedObjectID *)objectID
                 withContext:(NSManagedObjectContext *)context
                       error:(NSError *__autoreleasing *)error
{
    // always to-many
    NSMutableArray *objectIDs = [[NSMutableArray alloc] init];
    
    NSDictionary *entityCache = _cache[objectID.entity];
    
    // resourceIDs
    NSArray *values = entityCache[relationship.name];
    
    // convert
    for (NSNumber *destinationResourceID in values) {
        
        NSManagedObjectID *destinationObjectID = [self managedObjectIDForResourceID:destinationResourceID entity:relationship.destinationEntity];
        
        [objectIDs addObject:destinationObjectID];
    }
    
    return objectIDs;
}

#pragma mark - Saving

-(id)executeSaveRequest:(NSSaveChangesRequest *)request
            withContext:(NSManagedObjectContext *)context
                  error:(NSError *__autoreleasing *)error
{
    
    
    
    // increment version count after successful save
    
    _versionCount++;
    
    return @[];
}

-(NSArray *)obtainPermanentIDsForObjects:(NSArray *)array
                                   error:(NSError *__autoreleasing *)error
{
    NSMutableArray *objectIDs = [[NSMutableArray alloc] init];
    
    // create new resources
    for (NSManagedObject *newObject in array) {
        
        
    }
    
    // no errors occured
    
    // get permenant IDs
    
    
    
    return objectIDs;
}


@end
