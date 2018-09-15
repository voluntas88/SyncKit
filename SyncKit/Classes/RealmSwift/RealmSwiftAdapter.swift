//
//  RealmSwiftAdapter.swift
//  Pods
//
//  Created by Manuel Entrena on 29/08/2017.
//
//

import CloudKit
import RealmSwift
import Realm

func executeOnMainQueue(_ closure: () -> ()) {
    if Thread.isMainThread {
        closure()
    } else {
        DispatchQueue.main.sync {
            closure()
        }
    }
}

public protocol RealmSwiftAdapterDelegate {
    
    /**
     *  Asks the delegate to resolve conflicts for a managed object. The delegate is expected to examine the change dictionary and optionally apply any of those changes to the managed object.
     *
     *  @param adapter    The `QSRealmSwiftAdapter` that is providing the changes.
     *  @param changeDictionary Dictionary containing keys and values with changes for the managed object. Values can be [NSNull null] to represent a nil value.
     *  @param object           The `RLMObject` that has changed on iCloud.
     */
    func realmSwiftAdapter(_ adapter:RealmSwiftAdapter, gotChanges changes: [String: Any], object: Object)
}

struct ChildRelationship {
    
    let parentEntityName: String
    let childEntityName: String
    let childParentKey: String
}

struct RealmProvider {
    
    let persistenceRealm: Realm
    let targetRealm: Realm
    
    init?(persistenceConfiguration: Realm.Configuration, targetConfiguration: Realm.Configuration) {
        
        guard let persistenceRealm = try? Realm(configuration: persistenceConfiguration),
            let targetRealm = try? Realm(configuration: targetConfiguration) else {
                return nil
        }
        
        self.persistenceRealm = persistenceRealm
        self.targetRealm = targetRealm
    }
}

struct ObjectUpdate {
    
    enum UpdateType {
        case insertion
        case update
        case deletion
    }
    
    let object: Object
    let identifier: String
    let entityType: String
    let updateType: UpdateType
    let changes: [PropertyChange]?
}


public class RealmSwiftAdapter: NSObject, QSModelAdapter {
    
    public static let hasChangesNotification = Notification.Name("QSModelAdapterHasChangesNotification")
    
    static let shareRelationshipKey = "com.syncKit.shareRelationship"
    
    public let persistenceRealmConfiguration: Realm.Configuration
    public let targetRealmConfiguration: Realm.Configuration
    public let zoneID: CKRecordZoneID
    public var mergePolicy: QSModelAdapterMergePolicy = QSModelAdapterMergePolicy.server
    public var delegate: RealmSwiftAdapterDelegate?
    public var forceDataTypeInsteadOfAsset: Bool = false
    
    private var tempFileManager = QSTempFileManager()
    
    var realmProvider: RealmProvider!
    
    var collectionNotificationTokens = [NotificationToken]()
    var objectNotificationTokens = [String: NotificationToken]()
    var pendingTrackingUpdates = [ObjectUpdate]()
    var childRelationships = [String: Array<ChildRelationship>]()
    
    var hasChangesValue = false
    
    /* Should be initialized on main queue */
    public init(persistenceRealmConfiguration: Realm.Configuration, targetRealmConfiguration: Realm.Configuration, recordZoneID: CKRecordZoneID) {
        
        self.persistenceRealmConfiguration = persistenceRealmConfiguration
        self.targetRealmConfiguration = targetRealmConfiguration
        self.zoneID = recordZoneID
        
        super.init()
        
        executeOnMainQueue {
            setup()
            setupChildrenRelationshipsLookup()
        }
    }
    
    deinit {
        
        for token in objectNotificationTokens.values {
            token.invalidate()
        }
        for token in collectionNotificationTokens {
            token.invalidate()
        }
    }
    
    static public func defaultPersistenceConfiguration() -> Realm.Configuration {
        
        var configuration = Realm.Configuration()
        configuration.schemaVersion = 1
        configuration.migrationBlock = { migration, oldSchemaVersion in
            
        }
        configuration.objectTypes = [SyncedEntity.self, Record.self, PendingRelationship.self, ServerToken.self]
        return configuration
    }
    
    func setup() {
        
        realmProvider = RealmProvider(persistenceConfiguration: persistenceRealmConfiguration, targetConfiguration: targetRealmConfiguration)
        
        let needsInitialSetup = realmProvider.persistenceRealm.objects(SyncedEntity.self).count <= 0
        
        for schema in realmProvider.targetRealm.schema.objectSchema {
            
            let objectClass = realmObjectClass(name: schema.className)
            let primaryKey = objectClass.primaryKey()!
            let results = realmProvider.targetRealm.objects(objectClass)
            
            // Register for collection notifications
            let token = results.observe({ [weak self] (collectionChange) in
                
                switch collectionChange {
                case .update(_, _, let insertions, _):
                    
                    for index in insertions {
                        
                        let object = results[index]
                        let identifier = object.value(forKey: primaryKey) as! String
                        /* This can be called during a transaction, and it's illegal to add a notification block during a transaction,
                         * so we keep all the insertions in a list to be processed as soon as the realm finishes the current transaction
                         */
                        if object.realm!.isInWriteTransaction {
                            
                            self?.pendingTrackingUpdates.append(ObjectUpdate(object: object, identifier: identifier, entityType: schema.className, updateType: .insertion, changes: nil))
                        } else {
                            
                            self?.updateTracking(insertedObject: object, identifier: identifier, entityName: schema.className, provider: self!.realmProvider)
                        }
                    }
                default: break
                }
            })
            collectionNotificationTokens.append(token)
            
            // Register for object updates
            for object in results {
                
                let identifier = object.value(forKey: primaryKey) as! String
                let token = object.observe({ [weak self] (change) in
                    
                    switch change {
                    case .change(let properties):
                        
                        if object.realm!.isInWriteTransaction {
                            
                            self?.pendingTrackingUpdates.append(ObjectUpdate(object: object, identifier: identifier, entityType: schema.className, updateType: .update, changes: properties))
                        } else {
                            
                            self?.updateTracking(objectIdentifier: identifier, entityName: schema.className, inserted: false, deleted: false, changes: properties, realmProvider: self!.realmProvider)
                        }
                    case .deleted:
                        
                        if object.realm!.isInWriteTransaction {
                            
                            self?.pendingTrackingUpdates.append(ObjectUpdate(object: object, identifier: identifier, entityType: schema.className, updateType: .deletion, changes: nil))
                        } else {
                            
                            self?.updateTracking(objectIdentifier: identifier, entityName: schema.className, inserted: false, deleted: true, changes: nil, realmProvider: self!.realmProvider)
                        }
                        break
                    default: break
                    }
                })
                
                if needsInitialSetup {
                    
                    createSyncedEntity(entityType: schema.className, identifier: identifier, realm: realmProvider.persistenceRealm)
                }
                
                objectNotificationTokens[identifier] = token
            }
        }
        
        let token = realmProvider.targetRealm.observe { [weak self] (_, _) in
            
            self?.enqueueObjectUpdates()
        }
        collectionNotificationTokens.append(token)
        
        updateHasChanges(realm: realmProvider.persistenceRealm)
        
        if hasChangesValue {
            
            NotificationCenter.default.post(name: RealmSwiftAdapter.hasChangesNotification, object: self)
        }
    }
    
    func realmObjectClass(name: String) -> Object.Type {
        
        if let objClass = NSClassFromString(name) {
            return objClass as! Object.Type
        } else {
            let namespace = Bundle.main.infoDictionary!["CFBundleExecutable"] as! String
            return NSClassFromString("\(namespace).\(name)") as! Object.Type
        }
    }
    
    func updateHasChanges(realm: Realm) {
        
        let predicate = NSPredicate(format: "state != %ld", QSSyncedEntityState.synced.rawValue)
        let results = realm.objects(SyncedEntity.self).filter(predicate)
        
        hasChangesValue = results.count > 0;
    }
    
    func setupChildrenRelationshipsLookup() {
        
        childRelationships.removeAll()
        
        for objectSchema in realmProvider.targetRealm.schema.objectSchema {
            
            let objectClass = realmObjectClass(name: objectSchema.className)
            if let parentClass = objectClass.self as? QSParentKey.Type {
                let parentKey = parentClass.parentKey()
                let parentProperty = objectSchema.properties.first { $0.name == parentKey }
                
                let parentClassName = parentProperty!.objectClassName!
                let relationship = ChildRelationship(parentEntityName: parentClassName, childEntityName: objectSchema.className, childParentKey: parentKey)
                if childRelationships[parentClassName] == nil {
                    childRelationships[parentClassName] = Array<ChildRelationship>()
                }
                childRelationships[parentClassName]!.append(relationship)
            }
        }
    }
    
    func enqueueObjectUpdates() {
        
        if pendingTrackingUpdates.count > 0 {
            
            if realmProvider.targetRealm.isInWriteTransaction {
                
                DispatchQueue.main.async { [weak self] in
                    self?.enqueueObjectUpdates()
                }
            } else {
                
                updateObjectTracking()
            }
        }
    }
    
    func updateObjectTracking() {
        
        for update in pendingTrackingUpdates {
            
            if update.updateType == .insertion {
                
                updateTracking(insertedObject: update.object, identifier: update.identifier, entityName: update.entityType, provider: realmProvider)
            } else {
                
                updateTracking(objectIdentifier: update.identifier, entityName: update.entityType, inserted: false, deleted: (update.updateType == .deletion), changes: update.changes, realmProvider: realmProvider)
            }
        }
        
        pendingTrackingUpdates.removeAll()
    }
    
    func updateTracking(insertedObject: Object, identifier: String, entityName: String, provider: RealmProvider) {
        
        let token = insertedObject.observe { [weak self] (change) in
            
            switch change {
            case .change(let properties):
                
                self?.updateTracking(objectIdentifier: identifier, entityName: entityName, inserted: false, deleted: false, changes: properties, realmProvider: provider)
            case .deleted:
                
                self?.updateTracking(objectIdentifier: identifier, entityName: entityName, inserted: false, deleted: true, changes: nil, realmProvider: self!.realmProvider)
            default: break
            }
        }
        
        objectNotificationTokens[identifier] = token
        
        updateTracking(objectIdentifier: identifier, entityName: entityName, inserted: true, deleted: false, changes: nil, realmProvider: provider)
    }
    
    func updateTracking(objectIdentifier: String, entityName: String, inserted: Bool, deleted: Bool, changes: [PropertyChange]?, realmProvider: RealmProvider) {
        
        var isNewChange = false
        let identifier = "\(entityName).\(objectIdentifier)"
        let syncedEntity = getSyncedEntity(objectIdentifier: identifier, realm: realmProvider.persistenceRealm)
        
        if deleted {
            
            isNewChange = true
            
            if let syncedEntity = syncedEntity {
                realmProvider.persistenceRealm.beginWrite()
                syncedEntity.state = QSSyncedEntityState.deleted.rawValue
                try? realmProvider.persistenceRealm.commitWrite()
            }
            
            if let token = objectNotificationTokens[objectIdentifier] {
                
                objectNotificationTokens.removeValue(forKey: objectIdentifier)
                token.invalidate()
            }
            
        } else if syncedEntity == nil {
            
            createSyncedEntity(entityType: entityName, identifier: objectIdentifier, realm: realmProvider.persistenceRealm)
            
            if inserted {
                isNewChange = true
            }
            
        } else if !inserted {
            
            guard let syncedEntity = syncedEntity else {
                return
            }
            
            isNewChange = true
            
            var changedKeys: NSMutableSet
            if let changedKeysString = syncedEntity.changedKeys {
                changedKeys = NSMutableSet(array: changedKeysString.components(separatedBy: ","))
            } else {
                changedKeys = NSMutableSet()
            }
            
            if let changes = changes {
                for propertyChange in changes {
                    
                    changedKeys.add(propertyChange.name)
                }
            }
            
            realmProvider.persistenceRealm.beginWrite()
            syncedEntity.changedKeys = (changedKeys.allObjects as! [String]).joined(separator: ",")
            if syncedEntity.state == QSSyncedEntityState.synced.rawValue && !syncedEntity.changedKeys!.isEmpty {
                syncedEntity.state = QSSyncedEntityState.changed.rawValue
                // If state was New then leave it as that
            }
            try? realmProvider.persistenceRealm.commitWrite()
        }
        
        if !hasChangesValue && isNewChange {
            hasChangesValue = true
            NotificationCenter.default.post(name: RealmSwiftAdapter.hasChangesNotification, object: self)
        }
    }
    
    func commitTargetWriteTransactionWithoutNotifying() {
        
        try? realmProvider.targetRealm.commitWrite(withoutNotifying: Array(objectNotificationTokens.values))
    }
    
    @discardableResult
    func createSyncedEntity(entityType: String, identifier: String, realm: Realm) -> SyncedEntity {
        
        let syncedEntity = SyncedEntity(entityType: entityType, identifier: "\(entityType).\(identifier)", state: QSSyncedEntityState.new.rawValue)
        
        realm.beginWrite()
        realm.add(syncedEntity)
        try? realm.commitWrite()
        
        return syncedEntity
    }
    
    func createSyncedEntity(record: CKRecord, realmProvider: RealmProvider) -> SyncedEntity {
        
        let syncedEntity = SyncedEntity(entityType: record.recordType, identifier: record.recordID.recordName, state: QSSyncedEntityState.synced.rawValue)
        
        realmProvider.persistenceRealm.add(syncedEntity)
        
        let objectClass = realmObjectClass(name: record.recordType)
        let primaryKey = objectClass.primaryKey()!
        let objectIdentifier = getObjectIdentifier(for: syncedEntity)
        let object = objectClass.init()
        object.setValue(objectIdentifier, forKey: primaryKey)
        realmProvider.targetRealm.add(object)
        
        return syncedEntity;

    }
    
    func getObjectIdentifier(for syncedEntity: SyncedEntity) -> String {
        
        let range = syncedEntity.identifier.range(of: syncedEntity.entityType)!
        let index = syncedEntity.identifier.index(range.upperBound, offsetBy: 1)
        return syncedEntity.identifier.substring(from: index)
    }
    
    func syncedEntity(for object: Object, realm: Realm) -> SyncedEntity? {
        
        let objectClass = realmObjectClass(name: object.objectSchema.className)
        let primaryKey = objectClass.primaryKey()!
        let identifier = object.objectSchema.className + "." + (object.value(forKey: primaryKey) as! String)
        return getSyncedEntity(objectIdentifier: identifier, realm: realm)
    }
    
    func getSyncedEntity(objectIdentifier: String, realm: Realm) -> SyncedEntity? {
        
        return realm.object(ofType: SyncedEntity.self, forPrimaryKey: objectIdentifier)
    }
    
    func shouldIgnore(key: String) -> Bool {
        
        return QSCloudKitSynchronizer.synchronizerMetadataKeys().contains(key)
    }
    
    func applyChanges(in record: CKRecord, to object: Object, syncedEntity: SyncedEntity, realmProvider: RealmProvider) {
        
        if syncedEntity.state == QSSyncedEntityState.changed.rawValue || syncedEntity.state == QSSyncedEntityState.new.rawValue {
        
            if mergePolicy ==  QSModelAdapterMergePolicy.server {
                
                for property in object.objectSchema.properties {
                    if shouldIgnore(key: property.name) {
                        continue
                    }
                    if property.type == PropertyType.linkingObjects {
                        continue
                    }
                    
                    applyChange(property: property.name, record: record, object: object, syncedEntity: syncedEntity, realmProvider: realmProvider)
                }
                
            } else if mergePolicy == QSModelAdapterMergePolicy.client {
                
                let changedKeys: [String] = syncedEntity.changedKeys?.components(separatedBy: ",") ?? []
                
                for property in object.objectSchema.properties {
                    
                    if property.type == PropertyType.linkingObjects {
                        continue
                    }
                    
                    if !shouldIgnore(key: property.name) &&
                    !changedKeys.contains(property.name) &&
                        syncedEntity.state != QSSyncedEntityState.new.rawValue {
                        
                        applyChange(property: property.name, record: record, object: object, syncedEntity: syncedEntity, realmProvider: realmProvider)
                    }
                }
                
            } else if mergePolicy == QSModelAdapterMergePolicy.custom {
                
                var recordChanges = [String: Any]()
                
                for property in object.objectSchema.properties {
                    
                    if property.type == PropertyType.linkingObjects {
                        continue
                    }
                    
                    if !shouldIgnore(key: property.name) &&
                        !(record[property.name] is CKReference) {

                        if let asset = record[property.name] as? CKAsset {
                            recordChanges[property.name] = NSData(contentsOf: asset.fileURL)
                        } else {
                            recordChanges[property.name] = record[property.name] ?? NSNull()
                        }
                    }
                }
                
                delegate?.realmSwiftAdapter(self, gotChanges: recordChanges, object: object)
                
            }
        } else {
            
            for property in object.objectSchema.properties {
                
                if shouldIgnore(key: property.name) {
                    continue
                }
                if property.type == PropertyType.linkingObjects {
                    continue
                }
                
                applyChange(property: property.name, record: record, object: object, syncedEntity: syncedEntity, realmProvider: realmProvider)
            }
        }
    }
    
    func applyChange(property key: String, record: CKRecord, object: Object, syncedEntity: SyncedEntity, realmProvider: RealmProvider) {
        
        if key == object.objectSchema.primaryKeyProperty!.name {
            return
        }
        
        let value = record[key]
        if let reference = value as? CKReference {
            // Save relationship to be applied after all records have been downloaded and persisted
            // to ensure target of the relationship has already been created
            let recordName = reference.recordID.recordName
            let separatorRange = recordName.range(of: ".")!
            let objectIdentifier = recordName.substring(from: separatorRange.upperBound)
            savePendingRelationship(name: key, syncedEntity: syncedEntity, targetIdentifier: objectIdentifier, realm: realmProvider.persistenceRealm)
            
        } else if let referenceList = value as? [CKReference] {
            let referenceType = object.objectSchema.className
            let list = RLMArray<Object>(objectClassName: referenceType)
            let objectIdentifiers = referenceList.map { reference -> String in
                let recordName = reference.recordID.recordName
                let separatorRange = recordName.range(of: ".")!
                return recordName.substring(from: separatorRange.upperBound)
            }
            savePendingRelationship(name: key, syncedEntity: syncedEntity, targetIdentifiers: objectIdentifiers, realm: realmProvider.persistenceRealm)
        } else if let asset = value as? CKAsset {
            // Take data from asset url
            let data = NSData(contentsOf: asset.fileURL)
            object.setValue(data, forKey: key)
        } else {
            // If property is not a relationship or property is nil
            object.setValue(value, forKey: key)
        }
    }
    
    func savePendingRelationship(name: String, syncedEntity: SyncedEntity, targetIdentifier: String, realm: Realm) {
        
        let pendingRelationship = PendingRelationship()
        pendingRelationship.relationshipName = name
        pendingRelationship.forSyncedEntity = syncedEntity
        pendingRelationship.targetIdentifier = targetIdentifier
        realm.add(pendingRelationship)
    }
    
    func savePendingRelationship(name: String, syncedEntity: SyncedEntity, targetIdentifiers: [String], realm: Realm) {
        
        let pendingRelationship = PendingRelationship()
        pendingRelationship.relationshipName = name
        pendingRelationship.forSyncedEntity = syncedEntity
        pendingRelationship.toMany = true
        pendingRelationship.targetIdentifier = targetIdentifiers.joined(separator: "&&")
        print(pendingRelationship)
        realm.add(pendingRelationship)
    }
    
    func saveShareRelationship(for entity: SyncedEntity, record: CKRecord) {
        
        if let share = record.share {
            let relationship = PendingRelationship()
            relationship.relationshipName = RealmSwiftAdapter.shareRelationshipKey
            relationship.targetIdentifier = share.recordID.recordName
            relationship.forSyncedEntity = entity
            entity.realm?.add(relationship)
        }
    }
    
    func applyPendingRelationships(realmProvider: RealmProvider) {
        
        let pendingRelationships = realmProvider.persistenceRealm.objects(PendingRelationship.self)
        
        if pendingRelationships.count == 0 {
            return
        }
        
        realmProvider.persistenceRealm.beginWrite()
        realmProvider.targetRealm.beginWrite()
        for relationship in pendingRelationships {
            
            let syncedEntity = relationship.forSyncedEntity
            let originObjectClass = realmObjectClass(name: syncedEntity!.entityType)
            let objectIdentifier = getObjectIdentifier(for: syncedEntity!)
            let originObject = realmProvider.targetRealm.object(ofType: originObjectClass, forPrimaryKey: objectIdentifier)
            
            if relationship.relationshipName == RealmSwiftAdapter.shareRelationshipKey {
                syncedEntity?.share = getSyncedEntity(objectIdentifier: relationship.targetIdentifier, realm: realmProvider.persistenceRealm)
                realmProvider.persistenceRealm.delete(relationship)
                continue;
            }
            
            var targetClassName: String?
            for property in originObject!.objectSchema.properties {
                if property.name == relationship.relationshipName {
                    targetClassName = property.objectClassName
                    break
                }
            }
            
            guard let className = targetClassName else {
                continue
            }
            
            let targetObjectClass = realmObjectClass(name: className)
            let targetObject: Any?
            if relationship.toMany {
                targetObject = relationship
                    .targetIdentifier
                    .components(separatedBy: "&&")
                    .compactMap { targetIdentifier -> Object? in
                        realmProvider.targetRealm.object(ofType: targetObjectClass, forPrimaryKey: targetIdentifier)
                    }
            } else {
                targetObject = realmProvider
                    .targetRealm
                    .object(ofType: targetObjectClass, forPrimaryKey: relationship.targetIdentifier)
                
            }
            guard let origin = originObject, let target = targetObject else {
                continue
            }
            origin.setValue(target, forKey: relationship.relationshipName)
            
            realmProvider.persistenceRealm.delete(relationship)
        }
        
        try? realmProvider.persistenceRealm.commitWrite()
        commitTargetWriteTransactionWithoutNotifying()
    }
    
    func save(record: CKRecord, for syncedEntity: SyncedEntity) {
        
        if syncedEntity.record == nil {
            syncedEntity.record = Record()
        }
        
        syncedEntity.record!.encodedRecord = encodedRecord(record, onlySystemFields: true)
    }
    
    func encodedRecord(_ record: CKRecord, onlySystemFields: Bool) -> Data {
        
        let data = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWith: data)
        if onlySystemFields {
            record.encodeSystemFields(with: archiver)
        } else {
            record.encode(with: archiver)
        }
        archiver.finishEncoding()
        return data as Data
    }
    
    func getRecord(for syncedEntity: SyncedEntity) -> CKRecord? {
        
        var record: CKRecord?
        if let recordData = syncedEntity.record?.encodedRecord {
            let unarchiver = NSKeyedUnarchiver(forReadingWith: recordData)
            record = CKRecord(coder: unarchiver)
            unarchiver.finishDecoding()
        }
        return record
    }
    
    func save(share: CKShare, forSyncedEntity entity: SyncedEntity, realmProvider: RealmProvider) {
        
        var qsRecord: Record?
        if let entityForShare = entity.share {
            qsRecord = entityForShare.record
        } else {
            let entityForShare = createSyncedEntity(for: share, realmProvider: realmProvider)
            qsRecord = Record()
            realmProvider.persistenceRealm.add(qsRecord!)
            entityForShare.record = qsRecord
            entity.share = entityForShare
        }
        
        qsRecord?.encodedRecord = encodedRecord(share, onlySystemFields: false)
    }
    
    func getShare(for entity: SyncedEntity) -> CKShare? {
        
        if let recordData = entity.share?.record?.encodedRecord {
            let unarchiver = NSKeyedUnarchiver(forReadingWith: recordData)
            let share = CKShare(coder: unarchiver)
            unarchiver.finishDecoding()
            return share
        } else {
            return nil
        }
    }
    
    func createSyncedEntity(for share: CKShare, realmProvider: RealmProvider) -> SyncedEntity {
        
        let entityForShare = SyncedEntity()
        entityForShare.entityType = "CKShare"
        entityForShare.identifier = share.recordID.recordName
        entityForShare.updated = Date()
        entityForShare.state = QSSyncedEntityState.synced.rawValue
        realmProvider.persistenceRealm.add(entityForShare)
        
        return entityForShare
    }
    
    func nextStateToSync(after state: QSSyncedEntityState) -> QSSyncedEntityState {
        return QSSyncedEntityState(rawValue: state.rawValue + 1)!
    }
    
    func recordsToUpload(withState state: QSSyncedEntityState, limit: Int, realmProvider: RealmProvider) -> [CKRecord] {
        
        let predicate = NSPredicate(format: "state == %ld", state.rawValue)
        let results = realmProvider.persistenceRealm.objects(SyncedEntity.self).filter(predicate)
        var resultArray = [CKRecord]()
        for syncedEntity in results {
            
            if resultArray.count > limit {
                break
            }
            
            resultArray.append(recordToUpload(syncedEntity: syncedEntity, realmProvider: realmProvider))
        }
        
        return resultArray
    }
    
    func recordToUpload(syncedEntity: SyncedEntity, realmProvider: RealmProvider) -> CKRecord {
        
        let record = getRecord(for: syncedEntity) ?? CKRecord(recordType: syncedEntity.entityType, recordID: CKRecordID(recordName: syncedEntity.identifier, zoneID: zoneID))
        
        let objectClass = realmObjectClass(name: syncedEntity.entityType)
        let objectIdentifier = getObjectIdentifier(for: syncedEntity)
        let object = realmProvider.targetRealm.object(ofType: objectClass, forPrimaryKey: objectIdentifier)
        let entityState = syncedEntity.state
        
        let changedKeys = (syncedEntity.changedKeys ?? "").components(separatedBy: ",")
        
        var parentKey: String?
        if let childObject = object as? QSParentKey {
            parentKey = type(of: childObject).parentKey()
        }
        
        for property in object!.objectSchema.properties {
            
            if property.type == PropertyType.object &&
                (entityState == QSSyncedEntityState.new.rawValue || changedKeys.contains(property.name)) {
                
                if let target = object?.value(forKey: property.name) as? Object {
                    
                    let targetIdentifier = target.value(forKey: objectClass.primaryKey()!) as! String
                    let referenceIdentifier = "\(property.objectClassName!).\(targetIdentifier)"
                    let recordID = CKRecordID(recordName: referenceIdentifier, zoneID: zoneID)
                    // if we set the parent we must make the action .deleteSelf, otherwise we get errors if we ever try to delete the parent record
                    let action: CKReferenceAction = parentKey == property.name ? .deleteSelf : .none
                    let recordReference = CKReference(recordID: recordID, action: action)
                    record[property.name] = recordReference;
                } else if let listBase = object?[property.name] as? ListBase {
                    
                    var referenceList = [CKReference]()
                    for index in 0..<listBase._rlmArray.count {
                        if let target = listBase._rlmArray[index] as? Object {
                            let targetIdentifier = target.value(forKey: objectClass.primaryKey()!) as! String
                            let referenceIdentifier = "\(property.objectClassName!).\(targetIdentifier)"
                            let recordID = CKRecordID(recordName: referenceIdentifier, zoneID: zoneID)
                            // if we set the parent we must make the action .deleteSelf, otherwise we get errors if we ever try to delete the parent record
                            let action: CKReferenceAction = parentKey == property.name ? .deleteSelf : .none
                            let recordReference = CKReference(recordID: recordID, action: action)
                            referenceList.append(recordReference)
                        }
                    }
                    
                    if referenceList.count > 0 {
                        record[property.name] = referenceList as CKRecordValue
                    }
                    
                }
                
            } else if !property.isArray &&
            property.type != PropertyType.linkingObjects &&
            !(property.name == objectClass.primaryKey()!) &&
                (entityState == QSSyncedEntityState.new.rawValue || changedKeys.contains(property.name)) {
                
                let value = object!.value(forKey: property.name)
                if property.type == PropertyType.data,
                    let data = value as? Data,
                    forceDataTypeInsteadOfAsset == false,
                    let fileURL = self.tempFileManager.store(data) {
                    
                    let asset = CKAsset(fileURL: fileURL)
                    record[property.name] = asset
                } else if value == nil {
                    record[property.name] = nil
                } else if let recordValue = value as? CKRecordValue {
                    record[property.name] = recordValue
                }
            }
        }
        
        if let parentKey = parentKey,
            entityState == QSSyncedEntityState.new.rawValue || changedKeys.contains(parentKey),
            let reference = record[parentKey] as? CKReference {
            
            record.parent = CKReference(recordID: reference.recordID, action: .none)
        }
        
        return record;
    }
    
    // MARK: - Children records
    
    func childrenRecords(for syncedEntity: SyncedEntity) -> [CKRecord] {

        var records = [CKRecord]()
        records.append(recordToUpload(syncedEntity: syncedEntity, realmProvider: realmProvider))
        
        if let relationships = childRelationships[syncedEntity.entityType] {
            for relationship in relationships {
                
                let objectID = getObjectIdentifier(for: syncedEntity)
                if let objectClass = realmObjectClass(name: syncedEntity.entityType) as? Object.Type,
                    let object = realmProvider.targetRealm.object(ofType: objectClass.self, forPrimaryKey: objectID) {
                    
                    // Get children
                    let childObjectClass = realmObjectClass(name: relationship.childEntityName) as! Object.Type
                    let predicate = NSPredicate(format: "%K == %@", relationship.childParentKey, object)
                    let children = realmProvider.targetRealm.objects(childObjectClass.self).filter(predicate)
                    
                    for child in children {
                        if let childEntity = self.syncedEntity(for: child, realm: realmProvider.persistenceRealm) {
                            records.append(contentsOf: childrenRecords(for: childEntity))
                        }
                    }
                }
            }
        }
        
        return records
    }
    
//    - (RLMResults *)childrenOf:(RLMObject *)parent withRelationship:(QSChildRelationship *)relationship
//    {
//    Class objectClass = NSClassFromString(relationship.childEntityName);
//    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K == %@", relationship.childParentKey, parent];
//    return [objectClass objectsInRealm:parent.realm withPredicate:predicate];
//    }
    
    // MARK: - QSModelAdapter
    
    public func hasChanges() -> Bool {
        
        return hasChangesValue
    }
    
    public func prepareForImport() {
        
    }
    
    public func saveChanges(in records: [CKRecord]) {
        
        if records.count == 0 {
            return
        }
        
        executeOnMainQueue {
            self.realmProvider.persistenceRealm.beginWrite()
            self.realmProvider.targetRealm .beginWrite()
            
            for record in records {
                
                var syncedEntity: SyncedEntity! = getSyncedEntity(objectIdentifier: record.recordID.recordName, realm: self.realmProvider.persistenceRealm)
                if syncedEntity == nil {
                    if #available(iOS 10.0, *) {
                        if let share = record as? CKShare {
                            syncedEntity = createSyncedEntity(for: share, realmProvider: self.realmProvider)
                        } else {
                            syncedEntity = createSyncedEntity(record: record, realmProvider: self.realmProvider)
                        }
                    } else {
                        syncedEntity = createSyncedEntity(record: record, realmProvider: self.realmProvider)
                    }
                }
                
                if syncedEntity.state != QSSyncedEntityState.deleted.rawValue && syncedEntity.entityType != "CKShare" {
                    
                    let objectClass = realmObjectClass(name: record.recordType)
                    let objectIdentifier = getObjectIdentifier(for: syncedEntity)
                    guard let object = self.realmProvider.targetRealm.object(ofType: objectClass, forPrimaryKey: objectIdentifier) else {
                        continue
                    }
                    
                    applyChanges(in: record, to: object, syncedEntity: syncedEntity, realmProvider: self.realmProvider)
                    saveShareRelationship(for: syncedEntity, record: record)
                }
                
                save(record: record, for: syncedEntity)
            }
            // Order is important here. Notifications might be delivered after targetRealm is saved and
            // it's convenient if the persistenceRealm is not in a write transaction
            try? self.realmProvider.persistenceRealm.commitWrite()
            commitTargetWriteTransactionWithoutNotifying()
        }
    }
    
    public func deleteRecords(with recordIDs: [CKRecordID]) {
        
        if recordIDs.count == 0 {
            return
        }
        
        executeOnMainQueue {

            self.realmProvider.persistenceRealm.beginWrite()
            self.realmProvider.targetRealm.beginWrite()
            
            for recordID in recordIDs {
                
                if let syncedEntity = getSyncedEntity(objectIdentifier: recordID.recordName, realm: self.realmProvider.persistenceRealm) {
                    
                    if syncedEntity.entityType != "CKShare" {
                        
                        let objectClass = realmObjectClass(name: syncedEntity.entityType)
                        let objectIdentifier = getObjectIdentifier(for: syncedEntity)
                        let object = self.realmProvider.targetRealm.object(ofType: objectClass, forPrimaryKey: objectIdentifier)
                        
                        if let object = object {
                            
                            if let token = objectNotificationTokens[objectIdentifier] {
                                DispatchQueue.main.async {
                                    self.objectNotificationTokens.removeValue(forKey: objectIdentifier)
                                    token.invalidate()
                                }
                            }
                            self.realmProvider.targetRealm.delete(object)
                        }
                    }
                    
                    self.realmProvider.persistenceRealm.delete(syncedEntity)
                }
            }
            
            try? self.realmProvider.persistenceRealm.commitWrite()
            self.commitTargetWriteTransactionWithoutNotifying()
        }
    }
    
    public func persistImportedChanges(completion: @escaping ((Error?) -> Void)) {
        
        executeOnMainQueue {
            
            self.applyPendingRelationships(realmProvider: self.realmProvider)
        }
        
        completion(nil)
    }
    
    public func recordsToUpload(withLimit limit: Int) -> [CKRecord] {
        
        var recordsArray = [CKRecord]()
        
        executeOnMainQueue {
            
            let recordLimit = limit == 0 ? Int.max : limit
            var uploadingState = QSSyncedEntityState.new
            
            var innerLimit = recordLimit
            while recordsArray.count < recordLimit && uploadingState.rawValue < QSSyncedEntityState.deleted.rawValue {
                recordsArray.append(contentsOf: self.recordsToUpload(withState: uploadingState, limit: innerLimit, realmProvider: self.realmProvider))
                uploadingState = self.nextStateToSync(after: uploadingState)
                innerLimit = recordLimit - recordsArray.count
            }
        }
        
        return recordsArray
    }
    
    public func didUploadRecords(_ savedRecords: [CKRecord]) {
        
        executeOnMainQueue {
            
            self.realmProvider.persistenceRealm.beginWrite()
            for record in savedRecords {
                
                if let syncedEntity = self.realmProvider.persistenceRealm.object(ofType: SyncedEntity.self, forPrimaryKey: record.recordID.recordName) {
                    
                    syncedEntity.state = QSSyncedEntityState.synced.rawValue
                    syncedEntity.changedKeys = nil
                    self.save(record: record, for: syncedEntity)
                }
                
            }
            try? self.realmProvider.persistenceRealm.commitWrite()
        }
    }
    
    public func recordIDsMarkedForDeletion(withLimit limit: Int) -> [CKRecordID] {
        
        var recordIDs = [CKRecordID]()
        executeOnMainQueue {
            
            let predicate = NSPredicate(format: "state == %ld", QSSyncedEntityState.deleted.rawValue)
            let deletedEntities = self.realmProvider.persistenceRealm.objects(SyncedEntity.self).filter(predicate)
            
            for syncedEntity in deletedEntities {
                
                if recordIDs.count > limit {
                    break
                }
                recordIDs.append(CKRecordID(recordName: syncedEntity.identifier, zoneID: zoneID))
            }
        }
        
        return recordIDs
    }
    
    public func didDelete(_ deletedRecordIDs: [CKRecordID]) {
        
        executeOnMainQueue {
            
            self.realmProvider.persistenceRealm.beginWrite()
            for recordID in deletedRecordIDs {
                
                if let syncedEntity = self.realmProvider.persistenceRealm.object(ofType: SyncedEntity.self, forPrimaryKey: recordID.recordName) {
                    self.realmProvider.persistenceRealm.delete(syncedEntity)
                }
            }
            try? self.realmProvider.persistenceRealm.commitWrite()
        }
    }
    
    public func hasRecordID(_ recordID: CKRecordID) -> Bool {
        
        var hasRecord = false
        executeOnMainQueue {
            let syncedEntity = self.realmProvider.persistenceRealm.object(ofType: SyncedEntity.self, forPrimaryKey: recordID.recordName)
            hasRecord = syncedEntity != nil
        }
        return hasRecord
    }
    
    public func didFinishImportWithError(_ error: Error?) {
        
        tempFileManager.clearTempFiles()
        
        executeOnMainQueue {
            updateHasChanges(realm: self.realmProvider.persistenceRealm)
        }
    }
    
    public func record(for object: Any!) -> CKRecord? {
        
        guard let realmObject = object as? Object else {
            return nil
        }
        
        var record: CKRecord?
        
        executeOnMainQueue {
            if let syncedEntity = syncedEntity(for: realmObject, realm: self.realmProvider.persistenceRealm) {
                record = recordToUpload(syncedEntity: syncedEntity, realmProvider: self.realmProvider)
            }
        }
        
        return record
    }
    
    public func share(for object: Any!) -> CKShare? {
        
        guard let realmObject = object as? Object else {
            return nil
        }
        
        var share: CKShare?
        
        executeOnMainQueue {
            if let syncedEntity = syncedEntity(for: realmObject, realm: self.realmProvider.persistenceRealm) {
                share = getShare(for: syncedEntity)
            }
        }
        
        return share
    }
    
    public func save(_ share: CKShare, for object: Any!) {
        
        guard let realmObject = object as? Object else {
            return
        }
        
        executeOnMainQueue {
            if let syncedEntity = syncedEntity(for: realmObject, realm: self.realmProvider.persistenceRealm) {
                
                self.realmProvider.persistenceRealm.beginWrite()
                self.save(share: share, forSyncedEntity: syncedEntity, realmProvider: self.realmProvider)
                try? self.realmProvider.persistenceRealm.commitWrite()
            }
        }
    }
    
    public func deleteShare(for object: Any!) {
        
        guard let realmObject = object as? Object else {
            return
        }
        
        executeOnMainQueue {
            if let syncedEntity = syncedEntity(for: realmObject, realm: self.realmProvider.persistenceRealm),
                let shareEntity = syncedEntity.share {
                
                self.realmProvider.persistenceRealm.beginWrite()
                syncedEntity.share = nil
                if let record = shareEntity.record {
                    self.realmProvider.persistenceRealm.delete(record)
                }
                self.realmProvider.persistenceRealm.delete(shareEntity)
                try? self.realmProvider.persistenceRealm.commitWrite()
            }
        }
    }
    
    public func deleteChangeTracking() {
        
        let config = self.realmProvider.persistenceRealm.configuration
        let realmFileURLs: [URL] = [config.fileURL,
                             config.fileURL?.appendingPathExtension("lock"),
                             config.fileURL?.appendingPathExtension("note"),
                             config.fileURL?.appendingPathExtension("management")
            ].compactMap { $0 }
        
        for url in realmFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    public func recordZoneID() -> CKRecordZoneID {
        return zoneID
    }
    
    public func serverChangeToken() -> CKServerChangeToken? {
        
        var token: CKServerChangeToken?
        executeOnMainQueue {
            let serverToken = self.realmProvider.persistenceRealm.objects(ServerToken.self).first
            if let tokenData = serverToken?.token {
                token = NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
            }
        }
        return token
    }
    
    public func save(_ token: CKServerChangeToken?) {
        
        executeOnMainQueue {
            var serverToken: ServerToken! = self.realmProvider.persistenceRealm.objects(ServerToken.self).first
            
            self.realmProvider.persistenceRealm.beginWrite()
            
            if serverToken == nil {
                serverToken = ServerToken()
                self.realmProvider.persistenceRealm.add(serverToken)
            }
            
            if let token = token {
                serverToken.token = NSKeyedArchiver.archivedData(withRootObject: token)
            } else {
                serverToken.token = nil
            }
            
            try? self.realmProvider.persistenceRealm.commitWrite()
        }
    }
    
    public func recordsToUpdateParentRelationships(forRoot object: Any!) -> [CKRecord]! {
        guard let realmObject = object as? Object else {
            return nil
        }
        
        var records: [CKRecord]?
        executeOnMainQueue {
            if let syncedEntity = syncedEntity(for: realmObject, realm: self.realmProvider.persistenceRealm) {
                records = self.childrenRecords(for: syncedEntity)
            }
        }
        
        return records
    }
}
