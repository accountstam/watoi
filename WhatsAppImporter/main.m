//
//  main.m
//  WhatsApp Importer
//
//  Created by Anton S on 17/01/17.
//  Copyright © 2017 Anton S. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <sqlite3.h>

typedef enum {
    // I saw a msg with type == -1
    MSG_TEXT = 0,
    MSG_IMAGE = 1,
    MSG_AUDIO = 2,
    MSG_VIDEO = 3,
    MSG_CONTACT = 4,
    MSG_LOCATION = 5,
    MSG_CALL = 8,
    MSG_WTF = 10,
    MSG_WTF2 = 13,
} WAMsgType;

@interface Importer : NSObject
- (void) initializeCoreDataWithMomd:(NSString *)momdPath andDatabase:(NSString *)dbPath;
- (void) initializeAndroidStoreFromPath:(NSString *)storePath;
- (void) import;
@end

int main(int argc, const char * argv[]) {
    if (argc < 4) {
        NSLog(@"usage: %s <android sqlite> <momd> <iphone sqlite>", argv[0]);
        return 1;
    }

    @autoreleasepool {
        NSMutableArray *args = [NSMutableArray new];
        // Skip executable name
        for (unsigned int i = 1; i < argc; ++i) {
            [args addObject:[NSString stringWithCString:argv[i]]];
            NSLog(@"%@", [args objectAtIndex:(i-1)]);
        }

        Importer *imp = [Importer new];
        [imp initializeAndroidStoreFromPath:[args objectAtIndex:0]];
        [imp initializeCoreDataWithMomd:[args objectAtIndex:1]
                            andDatabase:[args objectAtIndex:2]];
        [imp import];
    }
    return 0;
}

// The meat

@interface Importer ()
@property (nonatomic, strong) NSManagedObjectContext *moc;
@property (nonatomic, strong) NSManagedObjectModel *mom;
@property (nonatomic, strong) NSPersistentStore *store;
@property (nonatomic) sqlite3 *androidStore;

@property (nonatomic, strong) NSMutableDictionary *chats;
@property (nonatomic, strong) NSMutableDictionary *chatMembers;

- (void) importChats;
- (void) saveCoreData;

// Debug stuff
- (void) dumpEntityDescriptions;
- (void) peekAndroidMessages;
- (void) peekiOSMessages;
@end

@implementation Importer

- (void) initializeCoreDataWithMomd:(NSString *)momdPath andDatabase:(NSString *)dbPath {
    NSURL *modelURL = [NSURL fileURLWithPath:momdPath];
    NSManagedObjectModel *mom = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    NSAssert(mom != nil, @"Error initializing Managed Object Model");
    self.mom = mom;

    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:mom];
    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [moc setPersistentStoreCoordinator:psc];
    self.moc = moc;

    NSError *error = nil;
    NSURL *storeURL = [NSURL fileURLWithPath:dbPath];
    NSPersistentStore *store = [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error];
    NSAssert(store != nil, @"Error initializing PSC: %@\n%@", [error localizedDescription], [error userInfo]);

    self.store = store;
    NSLog(@"CoreData loaded");
}

- (void) initializeAndroidStoreFromPath:(NSString *)storePath {
    sqlite3 *store = nil;

    if (sqlite3_open([storePath UTF8String], &store) != SQLITE_OK) {
        NSLog(@"%s", sqlite3_errmsg(store));
    }

    NSLog(@"Android store loaded");
    self.androidStore = store;
}

- (void) import {
    //[self dumpEntityDescriptions];
    [self importChats];
    [self importMessages];
}

- (void) dumpEntityDescriptions {
    for (NSEntityDescription* desc in self.mom.entities) {
        NSLog(@"%@\n\n", desc.name);
    }
}

- (void) peekiOSMessages {
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"WAMessage"];
    fetchRequest.returnsObjectsAsFaults = NO;
    [fetchRequest setFetchLimit:100];

    NSError *error = nil;
    NSArray *results = [self.moc executeFetchRequest:fetchRequest error:&error];
    if (!results) {
        NSLog(@"Error fetching objects: %@\n%@", [error localizedDescription], [error userInfo]);
        abort();
    }

    for (NSManagedObject *msg in results) {
        NSString *sender = [[msg valueForKey:@"isFromMe"] intValue] ?
                            @"me" : [msg valueForKey:@"fromJID"];
        NSLog(@"%@: %@", sender, [msg valueForKey:@"text"]);
    }
}

- (NSMutableArray *) executeQuery:(NSString *)query {
    NSNull *null = [NSNull null];  // Stupid singleton
    NSMutableArray *results = [NSMutableArray new];
    NSMutableArray *columnNames = nil;
    sqlite3_stmt *prepared;
    int totalColumns = 0;
    int result = FALSE;

    result = sqlite3_prepare_v2(self.androidStore, [query UTF8String], -1, &prepared, NULL);
    totalColumns = sqlite3_column_count(prepared);
    if (result != SQLITE_OK) {
        NSLog(@"%s", sqlite3_errmsg(self.androidStore));
        abort();
    }

    // It's a SELECT
    if (totalColumns > 0) {
        columnNames = [NSMutableArray arrayWithCapacity:totalColumns];
        for (int i = 0; i < totalColumns; ++i) {
            [columnNames addObject:[NSString stringWithUTF8String:sqlite3_column_name(prepared, i)]];
        }
    }

    // Fetching rows one by one
    while ((result = sqlite3_step(prepared)) == SQLITE_ROW) {
        NSMutableArray *row = [NSMutableArray arrayWithCapacity:totalColumns];
        int columnsCount = sqlite3_data_count(prepared);

        for (int i = 0; i < columnsCount; ++i) {
            int columnType = sqlite3_column_type(prepared, i);
            NSObject *value = nil;

            switch (columnType) {
                case SQLITE_INTEGER:
                    value = [NSNumber numberWithLongLong:sqlite3_column_int64(prepared, i)];
                    break;
                case SQLITE_FLOAT:
                    value = [NSNumber numberWithDouble:sqlite3_column_double(prepared, i)];
                    break;
                case SQLITE_TEXT:
                    value = [NSString stringWithUTF8String:(const char *) sqlite3_column_text(prepared, i)];
                    break;
                case SQLITE_BLOB: // Ignore blobs for now
                case SQLITE_NULL:
                    break;
            }

            if (!value) {
                value = null;
            }

            [row addObject:value];
        }

        [results addObject:[NSDictionary dictionaryWithObjects:row
                                                       forKeys:columnNames]];
    }

    sqlite3_finalize(prepared);
    return results;
}

- (void) peekAndroidMessages {
    NSMutableArray *results = nil;
    results = [self executeQuery:@"SELECT * FROM messages LIMIT 100;"];

    for (NSDictionary *row in results) {
        NSString *sender = [[row objectForKey:@"key_from_me"] intValue] ?
                            @"me" : [row objectForKey:@"key_remote_jid"];
        NSLog(@"%@: %@", sender, [row objectForKey:@"data"]);
    }
}

- (void) importChats {
    NSArray * androidChats = [self executeQuery:@"SELECT * FROM chat_list"];
    NSNull *null = [NSNull null];  // Stupid singleton

    // Support structures for messages import
    self.chats = [NSMutableDictionary new];
    self.chatMembers = [NSMutableDictionary new];

    for (NSDictionary *achat in androidChats) {
        NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"WAChatSession"
                                                               inManagedObjectContext:self.moc];
        BOOL isGroup = ([achat objectForKey:@"subject"] != null);
        NSString *chatJID = [achat objectForKey:@"key_remote_jid"];

        [chat setValue:chatJID forKey:@"contactJID"];

        NSNumber *archived = [NSNumber numberWithBool:([achat objectForKey:@"archived"] != null)];
        [chat setValue:archived forKey:@"archived"];

        // This field should contain contact name for non-groups
        NSString *partnerName = [achat objectForKey:@"subject"];
        if ((id) partnerName == null) {
            partnerName = @"";
        }
        [chat setValue:partnerName forKey:@"partnerName"];

        // FIXME
        [chat setValue:@0 forKey:@"messageCounter"];

        // We'll use this dict to link messages with chats
        [self.chats setObject:chat forKey:chatJID];

        if (!isGroup) {
            continue;
        }

        // Group chats should have associated GroupInfo objects
        NSManagedObject *group = [NSEntityDescription insertNewObjectForEntityForName:@"WAGroupInfo"
                                                               inManagedObjectContext:self.moc];
        // It's stored in millis in android db
        double sinceEpoch = ([[achat objectForKey:@"creation"] doubleValue] / 1000.0);
        [group setValue:[NSDate dateWithTimeIntervalSince1970:sinceEpoch] forKey:@"creationDate"];

        [group setValue:chat forKey:@"chatSession"];

        // Messages in groups are linked to members
        NSMutableDictionary *members = [NSMutableDictionary new];
        [self.chatMembers setObject:members forKey:chatJID];

        // Insert group members
        NSString *query = @"SELECT * from group_participants WHERE gjid == '%@'";
        NSMutableArray *amembers = [self executeQuery:[NSString stringWithFormat:query, chatJID]];
        for (NSDictionary *amember in amembers) {
            NSString *memberJID = [amember objectForKey:@"jid"];
            if ([memberJID isEqualToString:@""]) {
                // This entry corresponds to our account, should add it as well.
                // But how to get the JID?
                continue;
            }

            NSManagedObject *member = [NSEntityDescription insertNewObjectForEntityForName:@"WAGroupMember"
                                                                    inManagedObjectContext:self.moc];

            [member setValue:memberJID forKey:@"memberJID"];
            [member setValue:[amember objectForKey:@"admin"] forKey:@"isAdmin"];
            // Inactive members are in group_participants_history, I guess
            [member setValue:@YES forKey:@"isActive"];

            // FIXME Take it from wa.db
            NSString *fakeContactName = [memberJID componentsSeparatedByString:@"@"][0];
            [member setValue:fakeContactName forKey:@"contactName"];

            // Associate with current chat
            [member setValue:chat forKey:@"chatSession"];
            [members setObject:member forKey:memberJID];
        }
    }

    [self saveCoreData];
    NSLog(@"Loaded %lu chat(s)", (unsigned long)[androidChats count]);
}

- (void) importMessages {
    NSString *query = @"SELECT * FROM messages where"
                       " key_remote_jid == '%@'"
                       " AND status != 6"  // Some system messages
                       //" LIMIT 100;"
    ;
    id null = [NSNull null];  // Stupid singleton

    for (NSString *chatJID in self.chats) {
        NSManagedObject *chat = [self.chats objectForKey:chatJID];
        NSDictionary *members = [self.chatMembers objectForKey:chatJID];
        NSMutableArray * results = [self executeQuery:[NSString stringWithFormat:query, chatJID]];
        BOOL isGroup = ([chat valueForKey:@"groupInfo"] == null);
        NSLog(@"Importing messages for chat: %@", [chat valueForKey:@"contactJID"]);

        for (NSDictionary *amsg in results) {
            NSManagedObject *msg = [NSEntityDescription insertNewObjectForEntityForName:@"WAMessage"
                                                                 inManagedObjectContext:self.moc];
            BOOL fromMe = [[amsg objectForKey:@"key_from_me"] intValue];

            double sinceEpoch = ([[amsg objectForKey:@"timestamp"] doubleValue] / 1000.0);
            [msg setValue:[NSDate dateWithTimeIntervalSince1970:sinceEpoch] forKey:@"messageDate"];
            // TODO sentDate

            [msg setValue:[NSNumber numberWithBool:fromMe] forKey:@"isFromMe"];
            if (!fromMe) {
                [msg setValue:chatJID forKey:@"fromJID"];
                if (isGroup) {
                    NSString *senderJID = [amsg objectForKey:@"remote_resource"];
                    [msg setValue:[members objectForKey:senderJID] forKey:@"groupMember"];
                }
            } else {
                [msg setValue:chatJID forKey:@"toJID"];
            }

            // What is that? Some jabber stuff?
            [msg setValue:[amsg objectForKey:@"key_id"] forKey:@"stanzaID"];

            // IDK, all msgs in a real ChatStorage had @2 here
            [msg setValue:@2 forKey:@"dataItemVersion"];

            // Spotlight stuff?
            //        [msg setValue:@0 forKey:@"docID"];
            //        [msg setValue:@0 forKey:@"spotlightStatus"];
            // Don't know what is it
            //        [msg setValue:@0 forKey:@"flags"];
            //        [msg setValue:@0 forKey:@"groupEventType"];
            //        [msg setValue:@0 forKey:@"mediaSectionID"];
            //        [msg setValue:@0 forKey:@"messageStatus"];

            // Here goes the root of all suffering
            WAMsgType type = [[amsg objectForKey:@"media_wa_type"] intValue];
            NSString *text = [amsg objectForKey:@"data"]; // or null
            if (type != MSG_TEXT) {
                // Can't import media yet, but we'll have strange conversatios
                // if media messages are gone completely - put placeholders.
                NSString *prefix = null;
                switch (type) {
                    case MSG_IMAGE: prefix = @"<image>"; break;
                    case MSG_AUDIO: prefix = @"<audio>"; break;
                    case MSG_VIDEO: prefix = @"<video>"; break;
                    case MSG_CONTACT: prefix = @"<contact>"; break;
                    case MSG_LOCATION: prefix = @"<location>"; break;
                    case MSG_CALL: prefix = @"<call>"; break;
                    case MSG_WTF: prefix = @"<WTF>"; break;
                    case MSG_WTF2: prefix = @"<WTF>"; break;
                    case MSG_TEXT: break;
                }

                // Prepend media caption (if it exists) to the type
                NSString *caption = [amsg objectForKey:@"media_caption"];
                if ((id) caption != null) {
                    text = [NSString stringWithFormat:@"%@: %@", prefix, caption];
                } else {
                    text = prefix;
                }
            }
            [msg setValue:@(MSG_TEXT) forKey:@"messageType"];
            if ((id) text != null) {
                [msg setValue:text forKey:@"text"];
            } else {
                NSLog(@"null text detected: %@", amsg);
            }

            [msg setValue:chat forKey:@"chatSession"];
            //NSLog(@"(%d) %@", type, text);
        }
        [self saveCoreData];
    }
}

- (void) saveCoreData {
    NSError *error = nil;
    if ([self.moc save:&error] == NO) {
        NSAssert(NO, @"Error saving context: %@\n%@", [error localizedDescription], [error userInfo]);
    }
}

@end
