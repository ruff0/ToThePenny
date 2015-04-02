//
//  Fetch.m
//  Depoza
//
//  Created by Ivan Magda on 26.01.15.
//  Copyright (c) 2015 Ivan Magda. All rights reserved.
//
#import "Fetch.h"
#import "CategoriesInfo.h"

    //CoreData
#import "CategoryData.h"
#import "ExpenseData+Fetch.h"
#import "Persistence.h"

    //Categories
#import "NSDate+FirstAndLastDaysOfMonth.h"

static NSString * const kTodayExpensesUbiquitousKeyValueStoreKey = @"isNewToday";

@implementation Fetch

+ (NSArray *)getObjectsWithEntity:(NSString *)entityName predicate:(NSPredicate *)predicate context:(NSManagedObjectContext *)context sortKey:(NSString *)key {
    NSAssert(entityName.length > 0, @"Entity must has a legal Name!");
    NSParameterAssert(context);

    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];

    if (key) {
        NSSortDescriptor *sort = [[NSSortDescriptor alloc]initWithKey:key ascending:YES];
        [request setSortDescriptors:@[sort]];
    }

    if (predicate) {
        [request setPredicate:predicate];
    }

    NSError *error;
    NSArray *fetchedCategories = [context executeFetchRequest:request error:&error];
    if (error) {
        NSLog(@"***Error: %@", [error localizedDescription]);
    }

    return fetchedCategories;
}

+ (NSMutableArray *)loadCategoriesInfoInContext:(NSManagedObjectContext *)managedObjectContext totalExpeditures:(CGFloat *)totalExpeditures {
    [[Persistence sharedInstance]deduplication];
    
    NSArray *fetchedCategories = [self getObjectsWithEntity:NSStringFromClass([CategoryData class]) predicate:nil context:managedObjectContext sortKey:NSStringFromSelector(@selector(idValue))];

    NSMutableArray *categoriesInfo = [NSMutableArray arrayWithCapacity:[fetchedCategories count]];

        //NSParameterAssert(fetchedCategories != nil && [fetchedCategories count] > 0);

    NSMutableSet *categoriesIds = [NSMutableSet setWithCapacity:fetchedCategories.count];

        //Create array of categories infos
    for (CategoryData *aData in fetchedCategories) {
        CategoriesInfo *info = [[CategoriesInfo alloc]initWithTitle:aData.title iconName:aData.iconName idValue:aData.idValue andAmount:@0];
        NSParameterAssert(info.title && info.idValue && info.amount);
        [categoriesInfo addObject:info];

            //Check for unique id values
        if (![categoriesIds containsObject:aData.idValue]) {
            [categoriesIds addObject:aData.idValue];
        } else {
            NSLog(@"Categories must have a unique id values!!!");
            [[Persistence sharedInstance]deduplication];
        }
    }
    categoriesIds = nil;
    
    NSArray *days = [NSDate getFirstAndLastDaysInTheCurrentMonth];

    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass([CategoryData class])];
    [fetchRequest setRelationshipKeyPathsForPrefetching:@[NSStringFromSelector(@selector(expense))]];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"(SUBQUERY(expense, $x, ($x.dateOfExpense >= %@) AND ($x.dateOfExpense <= %@)).@count > 0)", [days firstObject], [days lastObject]];

    NSDate *start = [NSDate date];

    NSArray *categories = [managedObjectContext executeFetchRequest:fetchRequest error:nil];

    float __block countForExpenditures = 0.0f;

    for (CategoryData *category in categories) {
        [categoriesInfo enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CategoriesInfo *anInfo = obj;
            if (category.idValue == anInfo.idValue) {
                for (ExpenseData *expense in category.expense) {
                    anInfo.amount = @([anInfo.amount floatValue] + [expense.amount floatValue]);
                    countForExpenditures += [expense.amount floatValue];

                [managedObjectContext refreshObject:expense mergeChanges:NO];
                }
                *stop = YES;
            }
        }];
    }
    *totalExpeditures = countForExpenditures;

    NSDate *end = [NSDate date];
    NSLog(@"Second version with subquery and prefetching time execution: %f", [end timeIntervalSinceDate:start]);

    return categoriesInfo;
}

+ (BOOL)hasNewExpensesForTodayInManagedObjectContext:(NSManagedObjectContext *)context {
        //Get info about todays expenses from user defaults
    NSUbiquitousKeyValueStore *kvStore = [NSUbiquitousKeyValueStore defaultStore];
    NSDictionary *dictionaryInfo = [kvStore dictionaryForKey:kTodayExpensesUbiquitousKeyValueStoreKey];

        //Get today components
    NSDictionary *dateComponents = [[NSDate date]getComponents];
    NSInteger year  = [dateComponents[@"year"]integerValue];
    NSInteger month = [dateComponents[@"month"]integerValue];
    NSInteger day   = [dateComponents[@"day"]integerValue];

    NSArray *expenses = [ExpenseData getTodayExpensesInManagedObjectContext:context];

    if (dictionaryInfo == nil) {
        [self updateTodayExpensesCount:expenses day:day month:month year:year ubiquitousKeyValueStore:kvStore];
        return YES;
    } else {
        NSInteger yearDict    = [dictionaryInfo[@"year"]integerValue];
        NSInteger monthDict   = [dictionaryInfo[@"month"]integerValue];
        NSInteger dayDict     = [dictionaryInfo[@"day"]integerValue];
        NSInteger numExpenses = [dictionaryInfo[@"expenses"]integerValue];
        NSParameterAssert(numExpenses >= 0);

        if (yearDict == year && monthDict == month && dayDict == day) {
            if (numExpenses != expenses.count) {
                [self updateTodayExpensesCount:expenses day:day month:month year:year ubiquitousKeyValueStore:kvStore];
                return YES;
            } else {
                return NO;
            }
        } else {
            [self updateTodayExpensesCount:expenses day:day month:month year:year ubiquitousKeyValueStore:kvStore];
            return YES;
        }
    }
}

+ (NSDictionary *)setUpDictionaryWithYear:(NSInteger)year month:(NSInteger)month day:(NSInteger)day andNumberExpenses:(NSInteger)expenses {
    NSDictionary *dictionary = @{
                                 @"year"     : @(year),
                                 @"month"    : @(month),
                                 @"day"      : @(day),
                                 @"expenses" : @(expenses)
                                 };
    return dictionary;
}

+ (void)synchronizeUbiquitousKeyValueStore:(NSUbiquitousKeyValueStore *)kvStore withDictionary:(NSDictionary *)dictionary {
    [kvStore setDictionary:dictionary forKey:kTodayExpensesUbiquitousKeyValueStoreKey];
}

+ (void)updateTodayExpensesCount:(NSArray *)expenses day:(NSInteger)day month:(NSInteger)month year:(NSInteger)year ubiquitousKeyValueStore:(NSUbiquitousKeyValueStore *)kvStore
{
    NSDictionary *dictionaryInfo;
    dictionaryInfo = [self setUpDictionaryWithYear:year month:month day:day andNumberExpenses:expenses.count];
    [self synchronizeUbiquitousKeyValueStore:kvStore withDictionary:dictionaryInfo];
}

@end
