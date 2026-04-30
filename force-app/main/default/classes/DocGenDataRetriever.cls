public with sharing class DocGenDataRetriever {
    /**
     * Represents a parsed subquery with optional nested grandchild subqueries.
     * Used by the multi-level query stitcher to decompose configs like:
     * (SELECT Name, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities)
     */
    private class SubquerySpec {
        String relationshipName; // e.g., 'Opportunities'
        String childObjectApiName; // e.g., 'Opportunity'
        String parentIdField; // e.g., 'AccountId'
        String fieldsOnly; // e.g., 'Name, Amount' (no nested subqueries)
        String whereClause;
        String orderByClause;
        String limitClause;
        List<SubquerySpec> children = new List<SubquerySpec>();
    }

    /**
     * Executes a dynamic SOQL query based on the fields configuration and record ID.
     * Supports deep grandchild relationships via multi-level query stitching.
     *
     * Configs with nested subqueries like:
     *   Name, (SELECT Name, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities)
     * are decomposed into separate queries per level and stitched together.
     */
    /**
     * Represents a junction object configuration for two-hop queries.
     * E.g., Opportunity → OpportunityContactRoles → Contact
     */
    private class JunctionSpec {
        String junctionRel; // 'OpportunityContactRoles'
        List<String> junctionFields; // ['Role'] — fields from junction record itself
        String targetObject; // 'Contact'
        String targetIdField; // 'ContactId' — lookup field on junction to target
        List<String> targetFields; // ['FirstName', 'LastName', 'Email']
        String targetWhere;
        String targetOrderBy;
    }

    /**
     * Returns the query config version (1, 2, or 3) for a given fieldsConfig string.
     * Used by DocGenBatch to decide whether bulk caching is available.
     */
    public static Integer getConfigVersion(String fieldsConfig) {
        if (String.isBlank(fieldsConfig) || !fieldsConfig.trim().startsWith('{')) {
            return 1;
        }
        try {
            Map<String, Object> jsonConfig = (Map<String, Object>) JSON.deserializeUntyped(fieldsConfig.trim());
            Object versionObj = jsonConfig.get('v');
            return (versionObj != null) ? Integer.valueOf(String.valueOf(versionObj)) : 2;
        } catch (Exception e) {
            // Malformed JSON — fall back to V1 (legacy flat string format)
            return 1;
        }
    }

    /**
     * Executes a dynamic SOQL query based on the fields configuration and record ID.
     * Auto-detects config version (V1 flat, V2 JSON, V3 tree) and routes accordingly.
     * @param recordId The ID of the record to query
     * @param baseObject The API name of the base SObject
     * @param fieldsConfig The query configuration string (V1/V2/V3 format)
     * @return Map of field names to values, with child relationships nested
     */
    public static Map<String, Object> getRecordData(Id recordId, String baseObject, String fieldsConfig) {
        if (String.isBlank(baseObject) || String.isBlank(fieldsConfig) || recordId == null) {
            throw new DocGenException('Invalid parameters for data retrieval.');
        }

        // Strip outer SELECT / FROM if user pasted a full SOQL query (V1 flat strings only)
        fieldsConfig = fieldsConfig.trim();
        if (fieldsConfig.toUpperCase().startsWith('SELECT ') && !fieldsConfig.startsWith('{')) {
            fieldsConfig = fieldsConfig.substring(7).trim();
            // Find the last FROM at outermost paren level, strip it and everything after
            Integer lastFromAt = -1;
            Integer pLevel = 0;
            String upper = fieldsConfig.toUpperCase();
            for (Integer idx = 0; idx < fieldsConfig.length(); idx++) {
                String ch = fieldsConfig.substring(idx, idx + 1);
                if (ch == '(')
                    pLevel++;
                if (ch == ')')
                    pLevel--;
                if (pLevel == 0 && upper.substring(idx).startsWith('FROM ')) {
                    lastFromAt = idx;
                }
            }
            if (lastFromAt > 0) {
                fieldsConfig = fieldsConfig.substring(0, lastFromAt).trim();
                if (fieldsConfig.endsWith(',')) {
                    fieldsConfig = fieldsConfig.substring(0, fieldsConfig.length() - 1).trim();
                }
            }
        }

        // JSON config: route by version
        if (fieldsConfig.trim().startsWith('{')) {
            Map<String, Object> jsonConfig = (Map<String, Object>) JSON.deserializeUntyped(fieldsConfig.trim());
            Object versionObj = jsonConfig.get('v');
            Integer version = (versionObj != null) ? Integer.valueOf(String.valueOf(versionObj)) : 2;

            // V4: Custom Apex Data Provider
            if (version == 4) {
                return getRecordDataV4(recordId, jsonConfig);
            }
            if (version >= 3) {
                return getRecordDataV3(recordId, jsonConfig);
            }
            return getRecordDataV2(recordId, baseObject, fieldsConfig);
        }

        SObjectType objType = Schema.getGlobalDescribe().get(baseObject);
        if (objType == null) {
            throw new DocGenException('Invalid or inaccessible object.');
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Parse the config into flat fields, direct subqueries, and nested subquery specs
        List<String> flatParts = new List<String>();
        List<SubquerySpec> deepSpecs = new List<SubquerySpec>();
        parseConfigParts(fieldsConfig, baseObject, fieldMap, flatParts, deepSpecs);

        // Build Level 0 query: flat fields + direct child subqueries (no nesting)
        String level0Select = buildLevel0Select(flatParts, deepSpecs);
        if (String.isBlank(level0Select)) {
            level0Select = 'Id';
        }

        String query =
            'SELECT ' +
            level0Select +
            ' FROM ' +
            String.escapeSingleQuotes(baseObject) +
            ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> data;
        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - field names from template config validated by Schema describe; base object escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            data = mapSObject(results[0]);
        } catch (Exception e) {
            throw new DocGenException(
                'Error executing query. Please verify your template configuration: ' + e.getMessage()
            );
        }

        // 1.72 — getPopulatedFieldsAsMap() drops child relationships that
        // returned zero rows from the SOQL result. Synthesize empty
        // {records:[], totalSize:0} wrappers for every declared subquery so
        // {Rel.totalSize} resolves to 0 (not null) and {#IF Rel.totalSize != 0}
        // evaluates correctly on the empty case.
        List<String> declaredRels = new List<String>();
        for (SubquerySpec spec : deepSpecs) {
            if (String.isNotBlank(spec.relationshipName)) {
                declaredRels.add(spec.relationshipName);
            }
        }
        ensureChildRelKeys(data, declaredRels);

        // Stitch deeper levels (grandchildren, great-grandchildren)
        for (SubquerySpec spec : deepSpecs) {
            if (!spec.children.isEmpty()) {
                stitchGrandchildren(data, spec);
            }
        }

        return data;
    }

    /**
     * Parses the config string into flat fields/direct subqueries and deep subquery specs.
     * Nested subqueries are extracted so Level 0 only contains direct children.
     */
    /**
     * JSON v2 config parser. Builds SOQL from structured JSON, handles junctions.
     *
     * JSON format:
     * { "v":2, "baseObject":"Opportunity", "baseFields":["Name","Amount"],
     *   "parentFields":["Account.Name"], "children":[{"rel":"OpportunityLineItems","fields":["Name"]}],
     *   "junctions":[{"junctionRel":"OpportunityContactRoles","junctionFields":["Role"],
     *     "targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName","LastName"]}] }
     */
    private static Map<String, Object> getRecordDataV2(Id recordId, String baseObject, String jsonConfig) {
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(jsonConfig);

        // Schema validation: validate base object name
        SObjectType baseType = validateObjectName(baseObject);
        Map<String, SObjectField> baseFieldMap = baseType.getDescribe().fields.getMap();

        // Build SELECT clause from baseFields + parentFields + child subqueries + junction subqueries
        List<String> selectParts = new List<String>();

        // Base fields — validate each against schema
        List<Object> baseFields = (List<Object>) config.get('baseFields');
        if (baseFields != null) {
            for (Object f : baseFields) {
                String validated = validateField(String.valueOf(f).trim(), baseFieldMap);
                if (validated != null) {
                    selectParts.add(validated);
                }
            }
        }

        // Parent fields (Account.Name, Owner.Email) — validate each against schema
        List<Object> parentFields = (List<Object>) config.get('parentFields');
        if (parentFields != null) {
            for (Object f : parentFields) {
                String validated = validateField(String.valueOf(f).trim(), baseFieldMap);
                if (validated != null) {
                    selectParts.add(validated);
                }
            }
        }

        // Direct child subqueries
        List<Object> children = (List<Object>) config.get('children');
        List<SubquerySpec> childSpecs = new List<SubquerySpec>();
        if (children != null) {
            for (Object childObj : children) {
                Map<String, Object> child = (Map<String, Object>) childObj;
                String rel = (String) child.get('rel');
                List<Object> fields = (List<Object>) child.get('fields');
                if (rel == null || fields == null || fields.isEmpty()) {
                    continue;
                }

                // Validate child relationship against base object's child relationships
                SubquerySpec spec = new SubquerySpec();
                spec.relationshipName = rel;
                resolveChildSchema(spec, baseObject);

                // Validate child fields against the resolved child object type
                List<String> fieldNames = new List<String>();
                for (Object f : fields) {
                    fieldNames.add(String.valueOf(f));
                }
                SObjectType childObjType = null;
                if (String.isNotBlank(spec.childObjectApiName)) {
                    childObjType = Schema.getGlobalDescribe().get(spec.childObjectApiName);
                    if (childObjType != null) {
                        fieldNames = validateFieldList(fieldNames, childObjType);
                    }
                }
                if (fieldNames.isEmpty()) {
                    continue;
                }

                String subquery =
                    '(SELECT ' +
                    String.join(fieldNames, ', ') +
                    ' FROM ' +
                    String.escapeSingleQuotes(rel);
                try {
                    // Allowlist validation: ORDER BY fields verified against child object Schema field map
                    Map<String, Schema.SObjectField> childFieldMap = (childObjType != null)
                        ? childObjType.getDescribe().fields.getMap()
                        : null;
                    String w = sanitizeClause((String) child.get('where'), 'WHERE');
                    String o = sanitizeClause((String) child.get('orderBy'), 'ORDER BY', childFieldMap);
                    String l = sanitizeClause((String) child.get('limit'), 'LIMIT');
                    if (String.isNotBlank(w)) {
                        subquery += ' WHERE ' + w;
                    }
                    if (String.isNotBlank(o)) {
                        subquery += ' ORDER BY ' + o;
                    }
                    if (String.isNotBlank(l)) {
                        subquery += ' LIMIT ' + l;
                    }
                    subquery += ')';
                    selectParts.add(subquery);

                    // Track for grandchild stitching (if nested children exist)
                    spec.fieldsOnly = String.join(fieldNames, ', ');
                    childSpecs.add(spec);
                } catch (Exception e) {
                    // Invalid subquery config — skip this subquery
                    continue;
                }
            }
        }

        // Junction subqueries — query the junction relationship as a direct child
        List<JunctionSpec> junctionSpecs = new List<JunctionSpec>();
        List<Object> junctions = (List<Object>) config.get('junctions');
        if (junctions != null) {
            for (Object jObj : junctions) {
                Map<String, Object> j = (Map<String, Object>) jObj;
                JunctionSpec js = new JunctionSpec();
                js.junctionRel = (String) j.get('junctionRel');
                js.targetObject = (String) j.get('targetObject');
                js.targetIdField = (String) j.get('targetIdField');
                js.targetWhere = (String) j.get('targetWhere');
                js.targetOrderBy = (String) j.get('targetOrderBy');

                // Validate target object via Schema
                SObjectType targetType = validateObjectName(js.targetObject);

                // Validate junction relationship against base object's child relationships
                // to resolve the junction child object for field validation
                SubquerySpec juncSpec = new SubquerySpec();
                juncSpec.relationshipName = js.junctionRel;
                resolveChildSchema(juncSpec, baseObject);

                js.junctionFields = new List<String>();
                List<Object> jf = (List<Object>) j.get('junctionFields');
                if (jf != null) {
                    for (Object f : jf) {
                        js.junctionFields.add(String.valueOf(f));
                    }
                }
                // Validate junction fields against the junction child object
                if (String.isNotBlank(juncSpec.childObjectApiName)) {
                    SObjectType juncChildType = Schema.getGlobalDescribe().get(juncSpec.childObjectApiName);
                    if (juncChildType != null) {
                        js.junctionFields = validateFieldList(js.junctionFields, juncChildType);
                        // Validate targetIdField against the junction child object
                        Map<String, SObjectField> juncFieldMap = juncChildType.getDescribe().fields.getMap();
                        String validatedTargetIdField = validateField(js.targetIdField, juncFieldMap);
                        if (validatedTargetIdField != null) {
                            js.targetIdField = validatedTargetIdField;
                        }
                    }
                }

                js.targetFields = new List<String>();
                List<Object> tf = (List<Object>) j.get('targetFields');
                if (tf != null) {
                    for (Object f : tf) {
                        js.targetFields.add(String.valueOf(f));
                    }
                }
                // Validate target fields against the target object
                js.targetFields = validateFieldList(js.targetFields, targetType);

                junctionSpecs.add(js);

                // Build junction subquery: (SELECT ContactId, Role FROM OpportunityContactRoles)
                List<String> jqFields = new List<String>();
                jqFields.add(js.targetIdField); // Always need the lookup ID for stitching
                jqFields.addAll(js.junctionFields);
                selectParts.add(
                    '(SELECT ' +
                        String.join(jqFields, ', ') +
                        ' FROM ' +
                        String.escapeSingleQuotes(js.junctionRel) +
                        ')'
                );
            }
        }

        if (selectParts.isEmpty()) {
            selectParts.add('Id');
        }

        // Execute Level 0 query
        String query =
            'SELECT ' +
            String.join(selectParts, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(baseObject) +
            ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> data;
        try {
            List<SObject> results = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - field names from V2 query config; base object escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            data = mapSObject(results[0]);
        } catch (Exception e) {
            throw new DocGenException(
                'Error executing query. Please verify your template configuration: ' + e.getMessage()
            );
        }

        // 1.72 — synthesize empty wrappers for declared child + junction
        // relationships that returned zero rows. See V1 path comment.
        List<String> declaredRelsV2 = new List<String>();
        for (SubquerySpec spec : childSpecs) {
            if (String.isNotBlank(spec.relationshipName)) {
                declaredRelsV2.add(spec.relationshipName);
            }
        }
        for (JunctionSpec js : junctionSpecs) {
            if (String.isNotBlank(js.junctionRel)) {
                declaredRelsV2.add(js.junctionRel);
            }
        }
        ensureChildRelKeys(data, declaredRelsV2);

        // Stitch junction targets (two-hop: junction record → target object)
        for (JunctionSpec js : junctionSpecs) {
            stitchJunctionTargets(data, js);
        }

        return data;
    }

    /**
     * Stitches target object data into junction records.
     * E.g., for OpportunityContactRoles, queries Contacts by ID and
     * injects Contact data into each OCR record under the 'Contact' key.
     */
    private static void stitchJunctionTargets(Map<String, Object> data, JunctionSpec js) {
        // Allowlist validation: target object and fields verified against Schema
        SObjectType targetType = validateObjectName(js.targetObject);
        js.targetFields = validateFieldList(js.targetFields, targetType);
        // Allowlist validation: get field map for ORDER BY field validation
        Map<String, Schema.SObjectField> targetFieldMap = targetType.getDescribe().fields.getMap();

        Object junctionData = data.get(js.junctionRel);
        if (junctionData == null || !(junctionData instanceof Map<String, Object>)) {
            return;
        }

        Map<String, Object> jMap = (Map<String, Object>) junctionData;
        Object recordsObj = jMap.get('records');
        if (recordsObj == null || !(recordsObj instanceof List<Object>)) {
            return;
        }

        List<Object> junctionRecords = (List<Object>) recordsObj;
        if (junctionRecords.isEmpty()) {
            return;
        }

        // Collect target IDs from junction records
        Set<Id> targetIds = new Set<Id>();
        for (Object rec : junctionRecords) {
            if (rec instanceof Map<String, Object>) {
                Object idVal = ((Map<String, Object>) rec).get(js.targetIdField);
                if (idVal != null) {
                    try {
                        targetIds.add(Id.valueOf(String.valueOf(idVal)));
                    } catch (Exception e) {
                        // Intentionally swallowed — non-ID value in junction lookup
                        String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                    }
                }
            }
        }
        if (targetIds.isEmpty()) {
            return;
        }

        // Query target objects
        List<String> targetFieldList = new List<String>(js.targetFields);
        if (!targetFieldList.contains('Id')) {
            targetFieldList.add(0, 'Id');
        }

        String targetQuery =
            'SELECT ' +
            String.join(targetFieldList, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(js.targetObject) +
            ' WHERE Id IN :targetIds';
        if (String.isNotBlank(js.targetWhere)) {
            targetQuery += ' AND ' + sanitizeClause(js.targetWhere, 'WHERE');
        }
        if (String.isNotBlank(js.targetOrderBy)) {
            // Allowlist validation: ORDER BY fields verified against Schema.describeSObjects() field map
            targetQuery += ' ORDER BY ' + sanitizeClause(js.targetOrderBy, 'ORDER BY', targetFieldMap);
        }

        Map<Id, Map<String, Object>> targetMap = new Map<Id, Map<String, Object>>();
        try {
            // CxSAST: SOQL injection mitigated by Schema allowlist validation on object, fields, ORDER BY + keyword blocklist + USER_MODE
            List<SObject> targetRecs = Database.query(targetQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — dynamic elements allowlist-validated; USER_MODE enforced
            for (SObject targetRec : targetRecs) {
                targetMap.put(targetRec.Id, mapSObject(targetRec));
            }
        } catch (Exception e) {
            // Junction target query failed — skip stitching for this junction
            return;
        }

        // Stitch target data into each junction record
        for (Object rec : junctionRecords) {
            if (!(rec instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> jRec = (Map<String, Object>) rec;
            Object targetIdVal = jRec.get(js.targetIdField);
            if (targetIdVal == null) {
                continue;
            }

            Id targetId;
            try {
                targetId = Id.valueOf(String.valueOf(targetIdVal));
            } catch (Exception e) {
                // Non-ID value in target lookup — skip this junction record
                continue;
            }

            Map<String, Object> targetData = targetMap.get(targetId);
            if (targetData != null) {
                jRec.put(js.targetObject, targetData);
            }
        }
    }

    // =========================================================================
    // V3: Query Tree Walker — multiple related objects, any depth
    // =========================================================================

    /**
     * Inner class representing a node in the query tree.
     */
    private class TreeNode {
        String id;
        String objectApiName;
        List<String> fields;
        List<String> parentFields;
        String parentNodeId;
        String lookupField;
        String relationshipName;
        // Optional. When present, this is the data-map key AND the merge-tag
        // name (e.g. {#SubscriptionItems}). Lets the same parent→child
        // relationship appear multiple times with different WHERE clauses.
        String alias;
        String whereClause;
        String orderByClause;
        String limitClause;
        // Junction support
        Map<String, Object> junction;

        // Effective data-map key: alias if present, else relationshipName.
        String dataMapKey() {
            return String.isNotBlank(alias) ? alias : relationshipName;
        }
    }

    /**
     * Processes a JSON v3 query tree config. Walks the tree top-down,
     * executing one SOQL query per node and stitching results into the
     * parent's data map.
     */
    private static Map<String, Object> getRecordDataV3(Id recordId, Map<String, Object> config) {
        // Parse all nodes
        List<TreeNode> allNodes = new List<TreeNode>();
        Map<String, TreeNode> nodeMap = new Map<String, TreeNode>();

        List<Object> nodesJson = (List<Object>) config.get('nodes');
        if (nodesJson == null || nodesJson.isEmpty()) {
            throw new DocGenException('No query nodes defined.');
        }

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        for (Object nodeObj : nodesJson) {
            Map<String, Object> n = (Map<String, Object>) nodeObj;
            TreeNode tn = new TreeNode();
            tn.id = (String) n.get('id');
            tn.objectApiName = (String) n.get('object');
            // Fix __cs suffix: Custom Setting relationship name sometimes stored as object name
            if (tn.objectApiName != null && tn.objectApiName.endsWith('__cs') && gd.get(tn.objectApiName) == null) {
                tn.objectApiName = tn.objectApiName.removeEnd('s');
            }
            // Schema validation: validate object name
            SObjectType nodeType = validateObjectName(tn.objectApiName);

            tn.parentNodeId = (String) n.get('parentNode');
            tn.lookupField = (String) n.get('lookupField');
            tn.relationshipName = (String) n.get('relationshipName');
            tn.alias = (String) n.get('alias');
            tn.whereClause = (String) n.get('where');
            tn.orderByClause = (String) n.get('orderBy');
            tn.limitClause = (String) n.get('limit');
            tn.junction = (Map<String, Object>) n.get('junction');

            tn.fields = new List<String>();
            List<Object> flds = (List<Object>) n.get('fields');
            if (flds != null) {
                for (Object f : flds) {
                    tn.fields.add(String.valueOf(f));
                }
            }
            // Validate fields against schema
            tn.fields = validateFieldList(tn.fields, nodeType);

            tn.parentFields = new List<String>();
            List<Object> pFlds = (List<Object>) n.get('parentFields');
            if (pFlds != null) {
                for (Object f : pFlds) {
                    tn.parentFields.add(String.valueOf(f));
                }
            }
            // Validate parent fields against schema
            tn.parentFields = validateFieldList(tn.parentFields, nodeType);

            // Validate lookupField against schema if present
            if (String.isNotBlank(tn.lookupField)) {
                Map<String, SObjectField> nodeFieldMap = nodeType.getDescribe().fields.getMap();
                String validatedLookup = validateField(tn.lookupField, nodeFieldMap);
                if (validatedLookup != null) {
                    tn.lookupField = validatedLookup;
                }
            }

            allNodes.add(tn);
            nodeMap.put(tn.id, tn);
        }

        // Find root node (parentNode is null)
        TreeNode root = null;
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == null) {
                root = tn;
                break;
            }
        }
        if (root == null) {
            throw new DocGenException('No root node found in query tree.');
        }
        // Filtered subsets (alias) must be unique among siblings — otherwise two
        // nodes would write to the same parent data-map key and silently overwrite.
        Set<String> seenKeysPerParent = new Set<String>();
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == null) {
                continue;
            }
            String key = (tn.parentNodeId == null ? '' : tn.parentNodeId) + '::' + tn.dataMapKey();
            if (seenKeysPerParent.contains(key)) {
                throw new DocGenException(
                    'Duplicate loop key under same parent: ' +
                        tn.dataMapKey() +
                        '. Set a unique alias on each filtered subset.'
                );
            }
            seenKeysPerParent.add(key);
        }

        // Query root: SELECT fields, parentFields FROM object WHERE Id = :recordId
        List<String> rootSelect = new List<String>();
        rootSelect.addAll(root.fields);
        rootSelect.addAll(root.parentFields);
        if (rootSelect.isEmpty()) {
            rootSelect.add('Id');
        }

        String rootQuery =
            'SELECT ' +
            String.join(rootSelect, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(root.objectApiName) +
            ' WHERE Id = :recordId LIMIT 1';

        Map<String, Object> rootData;
        try {
            List<SObject> results = Database.query(rootQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 tree node fields from query config; object name escaped; runs with USER_MODE
            if (results.isEmpty()) {
                return null;
            }
            rootData = mapSObject(results[0]);
        } catch (Exception e) {
            throw new DocGenException(e.getMessage());
        }

        // Walk the tree: process children of each node
        processChildNodes(root.id, rootData, allNodes, nodeMap, true);

        return rootData;
    }

    /**
     * Bulk version of getRecordDataV3. Queries all records with a single IN clause
     * and processes all children in bulk. Returns a Map keyed by record Id.
     * Used by DocGenBatch to pre-cache data for all records in one transaction.
     */
    public static Map<Id, Map<String, Object>> getRecordDataV3Bulk(Set<Id> recordIds, Map<String, Object> config) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new Map<Id, Map<String, Object>>();
        }

        // Parse all nodes (same as single-record version)
        List<TreeNode> allNodes = new List<TreeNode>();
        Map<String, TreeNode> nodeMap = new Map<String, TreeNode>();

        List<Object> nodesJson = (List<Object>) config.get('nodes');
        if (nodesJson == null || nodesJson.isEmpty()) {
            throw new DocGenException('No query nodes defined.');
        }

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        for (Object nodeObj : nodesJson) {
            Map<String, Object> n = (Map<String, Object>) nodeObj;
            TreeNode tn = new TreeNode();
            tn.id = (String) n.get('id');
            tn.objectApiName = (String) n.get('object');
            // Fix __cs suffix: Custom Setting relationship name sometimes stored as object name
            if (tn.objectApiName != null && tn.objectApiName.endsWith('__cs') && gd.get(tn.objectApiName) == null) {
                tn.objectApiName = tn.objectApiName.removeEnd('s');
            }
            // Schema validation: validate object name
            SObjectType nodeType = validateObjectName(tn.objectApiName);

            tn.parentNodeId = (String) n.get('parentNode');
            tn.lookupField = (String) n.get('lookupField');
            tn.relationshipName = (String) n.get('relationshipName');
            tn.whereClause = (String) n.get('where');
            tn.orderByClause = (String) n.get('orderBy');
            tn.limitClause = (String) n.get('limit');
            tn.junction = (Map<String, Object>) n.get('junction');

            tn.fields = new List<String>();
            List<Object> flds = (List<Object>) n.get('fields');
            if (flds != null) {
                for (Object f : flds) {
                    tn.fields.add(String.valueOf(f));
                }
            }
            // Validate fields against schema
            tn.fields = validateFieldList(tn.fields, nodeType);

            tn.parentFields = new List<String>();
            List<Object> pFlds = (List<Object>) n.get('parentFields');
            if (pFlds != null) {
                for (Object f : pFlds) {
                    tn.parentFields.add(String.valueOf(f));
                }
            }
            // Validate parent fields against schema
            tn.parentFields = validateFieldList(tn.parentFields, nodeType);

            // Validate lookupField against schema if present
            if (String.isNotBlank(tn.lookupField)) {
                Map<String, SObjectField> nodeFieldMap = nodeType.getDescribe().fields.getMap();
                String validatedLookup = validateField(tn.lookupField, nodeFieldMap);
                if (validatedLookup != null) {
                    tn.lookupField = validatedLookup;
                }
            }

            allNodes.add(tn);
            nodeMap.put(tn.id, tn);
        }

        // Find root node
        TreeNode root = null;
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == null) {
                root = tn;
                break;
            }
        }
        if (root == null) {
            throw new DocGenException('No root node found in query tree.');
        }

        // Bulk root query: SELECT fields FROM object WHERE Id IN :recordIds
        List<String> rootSelect = new List<String>();
        rootSelect.addAll(root.fields);
        rootSelect.addAll(root.parentFields);
        if (rootSelect.isEmpty()) {
            rootSelect.add('Id');
        }
        if (!rootSelect.contains('Id')) {
            rootSelect.add(0, 'Id');
        }

        String rootQuery =
            'SELECT ' +
            String.join(rootSelect, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(root.objectApiName) +
            ' WHERE Id IN :recordIds';

        Map<Id, Map<String, Object>> allData = new Map<Id, Map<String, Object>>();
        try {
            List<SObject> results = Database.query(rootQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection - V3 tree node fields from query config; object name escaped; runs with USER_MODE
            for (SObject rec : results) {
                allData.put(rec.Id, mapSObject(rec));
            }
        } catch (Exception e) {
            throw new DocGenException(e.getMessage());
        }

        // Walk the tree in bulk: process children for all root records at once
        processChildNodesBulk(root.id, allData, allNodes, nodeMap);

        return allData;
    }

    /**
     * Recursively processes child nodes, querying and stitching results.
     * @param parentId The tree node ID of the parent
     * @param parentDataMap The parent's data map (single record) or null for batch
     * @param allNodes All tree nodes
     * @param nodeMap Map of node ID → TreeNode
     * @param isSingleParent True if parent is a single record (root), false if batch
     */
    private static void processChildNodes(
        String parentId,
        Map<String, Object> parentDataMap,
        List<TreeNode> allNodes,
        Map<String, TreeNode> nodeMap,
        Boolean isSingleParent
    ) {
        // Find children of this parent
        List<TreeNode> children = new List<TreeNode>();
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == parentId) {
                children.add(tn);
            }
        }

        for (TreeNode child : children) {
            if (String.isBlank(child.lookupField) || String.isBlank(child.relationshipName)) {
                continue;
            }

            // Collect parent record IDs
            Set<Id> parentIds = new Set<Id>();
            if (isSingleParent) {
                Object idVal = parentDataMap.get('Id');
                if (idVal != null) {
                    try {
                        parentIds.add(Id.valueOf(String.valueOf(idVal)));
                    } catch (Exception e) {
                        // Intentionally swallowed — non-ID value in parent record
                        String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                    }
                }
            }
            if (parentIds.isEmpty()) {
                continue;
            }

            // Build child query
            List<String> selectFields = new List<String>();
            if (!child.fields.contains('Id')) {
                selectFields.add('Id');
            }
            selectFields.addAll(child.fields);
            selectFields.addAll(child.parentFields);
            selectFields.add(child.lookupField);

            // Junction fields
            if (child.junction != null) {
                String targetIdField = (String) child.junction.get('targetIdField');
                if (String.isNotBlank(targetIdField) && !selectFields.contains(targetIdField)) {
                    selectFields.add(targetIdField);
                }
                List<Object> jFields = (List<Object>) child.junction.get('junctionFields');
                if (jFields != null) {
                    for (Object jf : jFields) {
                        String jfs = String.valueOf(jf);
                        if (!selectFields.contains(jfs)) {
                            selectFields.add(jfs);
                        }
                    }
                }
            }

            // Allowlist validation: object verified against Schema.getGlobalDescribe()
            SObjectType childObjType = validateObjectName(child.objectApiName);
            // Allowlist validation: get field map for ORDER BY field validation
            Map<String, Schema.SObjectField> childNodeFieldMap = childObjType.getDescribe().fields.getMap();

            String childQuery =
                'SELECT ' +
                String.join(selectFields, ', ') +
                ' FROM ' +
                String.escapeSingleQuotes(child.objectApiName) +
                ' WHERE ' +
                String.escapeSingleQuotes(child.lookupField) +
                ' IN :parentIds';
            List<SObject> childResults;
            try {
                if (String.isNotBlank(child.whereClause)) {
                    childQuery += ' AND ' + sanitizeClause(child.whereClause, 'WHERE');
                }
                // Allowlist validation: ORDER BY fields verified against Schema.describeSObjects() field map
                if (String.isNotBlank(child.orderByClause)) {
                    childQuery += ' ORDER BY ' + sanitizeClause(child.orderByClause, 'ORDER BY', childNodeFieldMap);
                }
                if (String.isNotBlank(child.limitClause)) {
                    childQuery += ' LIMIT ' + sanitizeClause(child.limitClause, 'LIMIT');
                }

                childResults = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — all dynamic elements allowlist-validated against Schema.describeSObjects() field map; USER_MODE enforced
            } catch (Exception e) {
                // Child query failed — skip this child relationship
                continue;
            }

            // Group by parent lookup field
            Map<Id, List<Map<String, Object>>> grouped = new Map<Id, List<Map<String, Object>>>();
            for (SObject rec : childResults) {
                Id parentRecId = (Id) rec.get(child.lookupField);
                if (!grouped.containsKey(parentRecId)) {
                    grouped.put(parentRecId, new List<Map<String, Object>>());
                }
                grouped.get(parentRecId).add(mapSObject(rec));
            }

            // Stitch into parent
            Object parentIdVal = parentDataMap.get('Id');
            if (parentIdVal != null) {
                Id parentRecId;
                try {
                    parentRecId = Id.valueOf(String.valueOf(parentIdVal));
                } catch (Exception e) {
                    // Non-ID value in parent Id field — skip stitching
                    continue;
                }

                List<Map<String, Object>> childRecords = grouped.containsKey(parentRecId)
                    ? grouped.get(parentRecId)
                    : new List<Map<String, Object>>();

                parentDataMap.put(
                    child.dataMapKey(),
                    new Map<String, Object>{ 'totalSize' => childRecords.size(), 'records' => childRecords }
                );

                // Junction stitching: if this node has a junction config, stitch target data
                if (child.junction != null) {
                    stitchJunctionForTree(childRecords, child.junction);
                }

                // Recurse: process this child's children for each child record
                for (Map<String, Object> childRec : childRecords) {
                    processChildNodes(child.id, childRec, allNodes, nodeMap, true);
                }
            }
        }
    }

    /**
     * Bulk version of processChildNodes. Processes children for ALL parent records
     * in a single SOQL query per child node level, then stitches results back.
     * @param parentNodeId The tree node ID of the parent
     * @param parentDataMaps Map of parent record Id → data map (all parents at this level)
     * @param allNodes All tree nodes
     * @param nodeMap Map of node ID → TreeNode
     */
    private static void processChildNodesBulk(
        String parentNodeId,
        Map<Id, Map<String, Object>> parentDataMaps,
        List<TreeNode> allNodes,
        Map<String, TreeNode> nodeMap
    ) {
        // Find children of this parent node
        List<TreeNode> children = new List<TreeNode>();
        for (TreeNode tn : allNodes) {
            if (tn.parentNodeId == parentNodeId) {
                children.add(tn);
            }
        }

        for (TreeNode child : children) {
            if (String.isBlank(child.lookupField) || String.isBlank(child.relationshipName)) {
                continue;
            }

            // Collect ALL parent record IDs
            Set<Id> parentIds = parentDataMaps.keySet();
            if (parentIds.isEmpty()) {
                continue;
            }

            // Build child query
            List<String> selectFields = new List<String>();
            if (!child.fields.contains('Id')) {
                selectFields.add('Id');
            }
            selectFields.addAll(child.fields);
            selectFields.addAll(child.parentFields);
            selectFields.add(child.lookupField);

            // Junction fields
            if (child.junction != null) {
                String targetIdField = (String) child.junction.get('targetIdField');
                if (String.isNotBlank(targetIdField) && !selectFields.contains(targetIdField)) {
                    selectFields.add(targetIdField);
                }
                List<Object> jFields = (List<Object>) child.junction.get('junctionFields');
                if (jFields != null) {
                    for (Object jf : jFields) {
                        String jfs = String.valueOf(jf);
                        if (!selectFields.contains(jfs)) {
                            selectFields.add(jfs);
                        }
                    }
                }
            }

            // Allowlist validation: object verified against Schema.getGlobalDescribe()
            SObjectType bulkChildObjType = validateObjectName(child.objectApiName);
            // Allowlist validation: get field map for ORDER BY field validation
            Map<String, Schema.SObjectField> bulkChildFieldMap = bulkChildObjType.getDescribe().fields.getMap();

            // Single query for ALL parents
            String childQuery =
                'SELECT ' +
                String.join(selectFields, ', ') +
                ' FROM ' +
                String.escapeSingleQuotes(child.objectApiName) +
                ' WHERE ' +
                String.escapeSingleQuotes(child.lookupField) +
                ' IN :parentIds';

            List<SObject> childResults;
            try {
                if (String.isNotBlank(child.whereClause)) {
                    childQuery += ' AND ' + sanitizeClause(child.whereClause, 'WHERE');
                }
                // Allowlist validation: ORDER BY fields verified against Schema.describeSObjects() field map
                if (String.isNotBlank(child.orderByClause)) {
                    childQuery += ' ORDER BY ' + sanitizeClause(child.orderByClause, 'ORDER BY', bulkChildFieldMap);
                }
                if (String.isNotBlank(child.limitClause)) {
                    childQuery += ' LIMIT ' + sanitizeClause(child.limitClause, 'LIMIT');
                }

                childResults = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — all dynamic elements allowlist-validated against Schema.describeSObjects() field map; USER_MODE enforced
            } catch (Exception e) {
                // Bulk child query failed — skip this child relationship
                continue;
            }

            // Group by parent lookup field
            Map<Id, List<Map<String, Object>>> grouped = new Map<Id, List<Map<String, Object>>>();
            for (SObject rec : childResults) {
                Id parentRecId = (Id) rec.get(child.lookupField);
                if (!grouped.containsKey(parentRecId)) {
                    grouped.put(parentRecId, new List<Map<String, Object>>());
                }
                grouped.get(parentRecId).add(mapSObject(rec));
            }

            // Stitch into each parent's data map
            Map<Id, Map<String, Object>> allChildDataMaps = new Map<Id, Map<String, Object>>();
            for (Id parentRecId : parentDataMaps.keySet()) {
                Map<String, Object> parentData = parentDataMaps.get(parentRecId);
                List<Map<String, Object>> childRecords = grouped.containsKey(parentRecId)
                    ? grouped.get(parentRecId)
                    : new List<Map<String, Object>>();

                parentData.put(
                    child.dataMapKey(),
                    new Map<String, Object>{ 'totalSize' => childRecords.size(), 'records' => childRecords }
                );

                // Junction stitching
                if (child.junction != null) {
                    stitchJunctionForTree(childRecords, child.junction);
                }

                // Collect child records for next-level recursion
                for (Map<String, Object> childRec : childRecords) {
                    Object childIdVal = childRec.get('Id');
                    if (childIdVal != null) {
                        try {
                            allChildDataMaps.put(Id.valueOf(String.valueOf(childIdVal)), childRec);
                        } catch (Exception e) {
                            // Intentionally swallowed — non-ID value in child record
                            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                        }
                    }
                }
            }

            // Recurse: process this child node's children for all child records
            if (!allChildDataMaps.isEmpty()) {
                processChildNodesBulk(child.id, allChildDataMaps, allNodes, nodeMap);
            }
        }
    }

    /**
     * Stitches junction target data into child records (tree version).
     * Same concept as stitchJunctionTargets but works with the tree node junction config.
     */
    private static void stitchJunctionForTree(
        List<Map<String, Object>> junctionRecords,
        Map<String, Object> junctionConfig
    ) {
        String targetObject = (String) junctionConfig.get('targetObject');
        String targetIdField = (String) junctionConfig.get('targetIdField');
        if (String.isBlank(targetObject) || String.isBlank(targetIdField)) {
            return;
        }

        // Schema validation: validate target object and fields
        SObjectType targetType = validateObjectName(targetObject);

        List<String> targetFields = new List<String>();
        List<Object> tfl = (List<Object>) junctionConfig.get('targetFields');
        if (tfl != null) {
            for (Object f : tfl) {
                targetFields.add(String.valueOf(f));
            }
        }
        // Validate target fields against schema
        targetFields = validateFieldList(targetFields, targetType);
        if (targetFields.isEmpty()) {
            return;
        }
        if (!targetFields.contains('Id')) {
            targetFields.add(0, 'Id');
        }

        // Collect target IDs
        Set<Id> targetIds = new Set<Id>();
        for (Map<String, Object> rec : junctionRecords) {
            Object idVal = rec.get(targetIdField);
            if (idVal != null) {
                try {
                    targetIds.add(Id.valueOf(String.valueOf(idVal)));
                } catch (Exception e) {
                    // Intentionally swallowed — non-ID value in junction target
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            }
        }
        if (targetIds.isEmpty()) {
            return;
        }

        // Query targets
        String tQuery =
            'SELECT ' +
            String.join(targetFields, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(targetObject) +
            ' WHERE Id IN :targetIds';

        Map<Id, Map<String, Object>> targetMap = new Map<Id, Map<String, Object>>();
        try {
            List<SObject> targetRecs = Database.query(tQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — dynamic elements allowlist-validated; USER_MODE enforced
            for (SObject rec : targetRecs) {
                targetMap.put(rec.Id, mapSObject(rec));
            }
        } catch (Exception e) {
            // Junction target query failed — skip stitching
            return;
        }

        // Stitch
        for (Map<String, Object> jRec : junctionRecords) {
            Object idVal = jRec.get(targetIdField);
            if (idVal == null) {
                continue;
            }
            try {
                Id tId = Id.valueOf(String.valueOf(idVal));
                Map<String, Object> tData = targetMap.get(tId);
                if (tData != null) {
                    jRec.put(targetObject, tData);
                }
            } catch (Exception e) {
                // Intentionally swallowed — non-ID value in target field
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }
    }

    private static void parseConfigParts(
        String fieldsConfig,
        String baseObject,
        Map<String, SObjectField> fieldMap,
        List<String> flatParts,
        List<SubquerySpec> deepSpecs
    ) {
        // Split by comma at paren level 0
        List<String> rawParts = splitTopLevel(fieldsConfig);

        for (String part : rawParts) {
            String trimmed = part.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }

            String upper = trimmed.toUpperCase();
            if (trimmed.startsWith('(') && upper.contains('SELECT') && upper.contains('FROM')) {
                // This is a subquery — check if it has nested subqueries
                SubquerySpec spec = parseSubquerySpec(trimmed, baseObject);
                if (spec != null) {
                    deepSpecs.add(spec);
                    // Build a flattened version for Level 0 (strip nested subqueries)
                    String flatSubquery = buildFlatSubquery(spec);
                    flatParts.add(flatSubquery);
                }
                // If parse fails: drop the token. Earlier code passed it through with
                // String.escapeSingleQuotes, which is near-useless for unquoted SOQL —
                // an unparseable subquery should never reach Database.query.
            } else {
                // Regular field — validate
                String validated = validateField(trimmed, fieldMap);
                if (validated != null) {
                    flatParts.add(validated);
                }
            }
        }
    }

    /**
     * Splits a config string by commas, respecting parenthesis nesting.
     */
    private static List<String> splitTopLevel(String input) {
        List<String> parts = new List<String>();
        String current = '';
        Integer parenLevel = 0;

        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);

            // Auto-split field from adjacent subquery: "Account.Name (SELECT..."
            if (ch == '(' && parenLevel == 0 && String.isNotBlank(current.trim())) {
                parts.add(current.trim());
                current = '';
            }

            if (ch == '(') {
                parenLevel++;
            }
            if (ch == ')') {
                parenLevel--;
            }

            if (ch == ',' && parenLevel == 0) {
                parts.add(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
        if (String.isNotBlank(current.trim())) {
            parts.add(current.trim());
        }
        return parts;
    }

    /**
     * Parses a subquery string into a SubquerySpec, extracting any nested subqueries.
     * Input: (SELECT Name, Amount, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities WHERE ...)
     */
    private static SubquerySpec parseSubquerySpec(String subqueryStr, String parentObject) {
        // Strip outer parens
        String innerStr = subqueryStr.trim();
        if (innerStr.startsWith('(')) {
            innerStr = innerStr.substring(1);
        }
        if (innerStr.endsWith(')')) {
            innerStr = innerStr.substring(0, innerStr.length() - 1);
        }
        innerStr = innerStr.trim();

        // Extract: SELECT <fields> FROM <relationship> [WHERE ...] [ORDER BY ...] [LIMIT ...]
        String upperInner = innerStr.toUpperCase();
        Integer selectIdx = upperInner.indexOf('SELECT ');
        Integer fromIdx = findKeywordAtLevel0(innerStr, 'FROM');
        if (selectIdx == -1 || fromIdx == -1) {
            return null;
        }

        String fieldsPart = innerStr.substring(selectIdx + 7, fromIdx).trim();
        String afterFrom = innerStr.substring(fromIdx + 5).trim();

        // Extract relationship name and optional WHERE/ORDER BY/LIMIT
        String relationshipName;
        String whereClause;
        String orderByClause;
        String limitClause;

        Integer whereIdx = findKeywordAtLevel0(afterFrom, 'WHERE');
        Integer orderIdx = findKeywordAtLevel0(afterFrom, 'ORDER');
        Integer limitIdx = findKeywordAtLevel0(afterFrom, 'LIMIT');

        Integer firstClauseIdx = afterFrom.length();
        if (whereIdx != -1 && whereIdx < firstClauseIdx) {
            firstClauseIdx = whereIdx;
        }
        if (orderIdx != -1 && orderIdx < firstClauseIdx) {
            firstClauseIdx = orderIdx;
        }
        if (limitIdx != -1 && limitIdx < firstClauseIdx) {
            firstClauseIdx = limitIdx;
        }

        relationshipName = afterFrom.substring(0, firstClauseIdx).trim();

        whereClause = (whereIdx != -1) ? extractClause(afterFrom, whereIdx + 6, orderIdx, limitIdx) : null;
        orderByClause = (orderIdx != -1) ? extractClause(afterFrom, orderIdx + 9, limitIdx, -1) : null;
        limitClause = (limitIdx != -1) ? afterFrom.substring(limitIdx + 6).trim() : null;

        SubquerySpec spec = new SubquerySpec();
        spec.relationshipName = relationshipName;
        spec.whereClause = whereClause;
        spec.orderByClause = orderByClause;
        spec.limitClause = limitClause;

        // Resolve child object and parent ID field from Schema
        resolveChildSchema(spec, parentObject);

        // Check if fieldsPart contains nested subqueries
        List<String> fieldTokens = splitTopLevel(fieldsPart);
        List<String> plainFields = new List<String>();

        for (String token : fieldTokens) {
            String trimToken = token.trim();
            String upperToken = trimToken.toUpperCase();
            if (trimToken.startsWith('(') && upperToken.contains('SELECT') && upperToken.contains('FROM')) {
                // Nested subquery — parse as grandchild
                if (String.isNotBlank(spec.childObjectApiName)) {
                    SubquerySpec grandchild = parseSubquerySpec(trimToken, spec.childObjectApiName);
                    if (grandchild != null) {
                        spec.children.add(grandchild);
                    }
                }
            } else if (String.isNotBlank(trimToken)) {
                plainFields.add(trimToken);
            }
        }

        // Always include Id for stitching
        Boolean hasId = false;
        for (String f : plainFields) {
            if (f.equalsIgnoreCase('Id')) {
                hasId = true;
                break;
            }
        }
        if (!hasId) {
            plainFields.add(0, 'Id');
        }

        spec.fieldsOnly = String.join(plainFields, ', ');
        return spec;
    }

    /**
     * Finds a SOQL keyword at parenthesis level 0 (not inside a subquery).
     */
    private static Integer findKeywordAtLevel0(String input, String keyword) {
        String upper = input.toUpperCase();
        String target = ' ' + keyword.toUpperCase() + ' ';
        Integer parenLvl = 0;
        // Also check at start of string
        if (upper.startsWith(keyword.toUpperCase() + ' ') && parenLvl == 0) {
            return 0;
        }

        for (Integer i = 0; i < input.length(); i++) {
            String ch = input.substring(i, i + 1);
            if (ch == '(') {
                parenLvl++;
            }
            if (ch == ')') {
                parenLvl--;
            }
            if (parenLvl == 0 && i + target.length() <= upper.length()) {
                if (upper.substring(i, i + target.length()) == target) {
                    return i + 1; // position of keyword (after the space)
                }
            }
        }
        return -1;
    }

    /**
     * Extracts a clause value between the current keyword and the next keyword.
     */
    private static String extractClause(String source, Integer startIdx, Integer nextIdx1, Integer nextIdx2) {
        Integer endIdx = source.length();
        if (nextIdx1 != -1 && nextIdx1 < endIdx) {
            endIdx = nextIdx1;
        }
        if (nextIdx2 != -1 && nextIdx2 < endIdx) {
            endIdx = nextIdx2;
        }
        return source.substring(startIdx, endIdx).trim();
    }

    /**
     * Allowlist validation: relationship name verified against Schema.describeSObjects().getChildRelationships().
     * Resolves the child object API name and parent lookup field from Schema.
     */
    private static void resolveChildSchema(SubquerySpec spec, String parentObjectName) {
        SObjectType parentType = Schema.getGlobalDescribe().get(parentObjectName);
        if (parentType == null) {
            return;
        }

        for (Schema.ChildRelationship cr : parentType.getDescribe().getChildRelationships()) {
            if (cr.getRelationshipName() == spec.relationshipName) {
                spec.childObjectApiName = String.valueOf(cr.getChildSObject());
                spec.parentIdField = String.valueOf(cr.getField());
                return;
            }
        }

        // Fallback: user may have typed the object name (Short_Code__c) instead of the
        // relationship name (Short_Codes__r). Find the child relationship by object name
        // and correct the spec's relationshipName so the SOQL subquery uses the right FROM.
        for (Schema.ChildRelationship cr : parentType.getDescribe().getChildRelationships()) {
            if (
                cr.getRelationshipName() != null &&
                String.valueOf(cr.getChildSObject()).equalsIgnoreCase(spec.relationshipName)
            ) {
                spec.childObjectApiName = String.valueOf(cr.getChildSObject());
                spec.parentIdField = String.valueOf(cr.getField());
                spec.relationshipName = cr.getRelationshipName();
                return;
            }
        }

        // Child relationship not found — throw to prevent unvalidated relationship names in SOQL
        throw new DocGenException(
            'Invalid or inaccessible child relationship: ' + spec.relationshipName + ' on ' + parentObjectName
        );
    }

    /**
     * Builds a flat subquery for Level 0 (strips nested grandchild subqueries).
     * SOQL injection mitigation:
     *   - relationshipName is allowlist-validated by resolveChildSchema (throws if not in
     *     parent describe's child relationships).
     *   - fieldsOnly tokens are allowlist-validated against the child object's field map
     *     before concatenation (parseSubquerySpec leaves them raw; we validate here).
     *   - WHERE/ORDER BY/LIMIT routed through sanitizeClause (keyword blocklist + numeric LIMIT
     *     + Schema-allowlist for ORDER BY field names) — same gate V2/V3 paths use. Earlier
     *     versions used String.escapeSingleQuotes here, which is near-useless for unquoted
     *     SOQL clauses; that path is closed.
     */
    private static String buildFlatSubquery(SubquerySpec spec) {
        // Resolve child object field map for fields + ORDER BY allowlist validation
        Map<String, Schema.SObjectField> childFieldMap = null;
        if (String.isNotBlank(spec.childObjectApiName)) {
            SObjectType childType = Schema.getGlobalDescribe().get(spec.childObjectApiName);
            if (childType != null) {
                childFieldMap = childType.getDescribe().fields.getMap();
            }
        }

        // Validate fieldsOnly tokens against the child describe. Drop unknown tokens
        // (matches V2 silent-drop behavior). If everything got dropped, fall back to Id.
        String validatedFields;
        if (childFieldMap != null && String.isNotBlank(spec.fieldsOnly)) {
            List<String> validated = new List<String>();
            for (String token : spec.fieldsOnly.split(',')) {
                String v = validateField(token.trim(), childFieldMap);
                if (v != null) {
                    validated.add(v);
                }
            }
            validatedFields = validated.isEmpty() ? 'Id' : String.join(validated, ', ');
        } else {
            // No describe available — keep prior behavior with single-quote escape as
            // a last-ditch defense. resolveChildSchema would have thrown if the parent
            // describe didn't yield a child; this branch is effectively unreachable for
            // valid configs.
            validatedFields = String.isBlank(spec.fieldsOnly) ? 'Id' : String.escapeSingleQuotes(spec.fieldsOnly);
        }

        String sq = '(SELECT ' + validatedFields + ' FROM ' + String.escapeSingleQuotes(spec.relationshipName);
        if (String.isNotBlank(spec.whereClause)) {
            sq += ' WHERE ' + sanitizeClause(spec.whereClause, 'WHERE');
        }
        if (String.isNotBlank(spec.orderByClause)) {
            sq += ' ORDER BY ' + sanitizeClause(spec.orderByClause, 'ORDER BY', childFieldMap);
        }
        if (String.isNotBlank(spec.limitClause)) {
            sq += ' LIMIT ' + sanitizeClause(spec.limitClause, 'LIMIT');
        }
        sq += ')';
        return sq;
    }

    /**
     * Builds the Level 0 SELECT clause from validated flat parts.
     */
    private static String buildLevel0Select(List<String> parts, List<SubquerySpec> specs) {
        String result = '';
        for (String part : parts) {
            if (String.isNotBlank(result)) {
                result += ', ';
            }
            result += part;
        }
        return result;
    }

    /**
     * Stitches grandchild data into the data map via follow-up queries.
     * For each child record in the parent's child list, queries grandchildren
     * using IN :parentIds and injects them into the child record's map.
     */
    private static void stitchGrandchildren(Map<String, Object> data, SubquerySpec parentSpec) {
        // Get the child records list from the data map
        Object childData = data.get(parentSpec.relationshipName);
        if (childData == null || !(childData instanceof Map<String, Object>)) {
            return;
        }

        Map<String, Object> childMap = (Map<String, Object>) childData;
        Object recordsObj = childMap.get('records');
        if (recordsObj == null || !(recordsObj instanceof List<Object>)) {
            return;
        }

        List<Object> childRecords = (List<Object>) recordsObj;
        if (childRecords.isEmpty()) {
            return;
        }

        // For each grandchild spec, query and stitch
        for (SubquerySpec grandchildSpec : parentSpec.children) {
            if (String.isBlank(grandchildSpec.childObjectApiName) || String.isBlank(grandchildSpec.parentIdField)) {
                continue;
            }

            // Collect parent IDs
            Set<Id> parentIds = new Set<Id>();
            for (Object rec : childRecords) {
                if (rec instanceof Map<String, Object>) {
                    Object idVal = ((Map<String, Object>) rec).get('Id');
                    if (idVal != null) {
                        try {
                            parentIds.add(Id.valueOf(String.valueOf(idVal)));
                        } catch (Exception e) {
                            // Intentionally swallowed — non-ID value in child record
                            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                        }
                    }
                }
            }
            if (parentIds.isEmpty()) {
                continue;
            }

            // Query grandchildren
            // Allowlist validation: grandchild object verified against Schema.getGlobalDescribe()
            SObjectType gcObjType = validateObjectName(grandchildSpec.childObjectApiName);
            Map<String, Schema.SObjectField> gcFieldMap = gcObjType.getDescribe().fields.getMap();

            // Allowlist validation: fieldsOnly tokens were parsed from raw user config in
            // parseSubquerySpec; revalidate each against the resolved grandchild describe
            // before concatenation into SOQL.
            List<String> gcValidatedFields = new List<String>();
            if (String.isNotBlank(grandchildSpec.fieldsOnly)) {
                for (String token : grandchildSpec.fieldsOnly.split(',')) {
                    String v = validateField(token.trim(), gcFieldMap);
                    if (v != null) {
                        gcValidatedFields.add(v);
                    }
                }
            }
            if (gcValidatedFields.isEmpty()) {
                gcValidatedFields.add('Id');
            }
            // parentIdField comes from Schema.ChildRelationship.getField() (resolveChildSchema)
            // — already allowlist-trusted, but escape defensively before concat.
            if (!gcValidatedFields.contains(grandchildSpec.parentIdField)) {
                gcValidatedFields.add(String.escapeSingleQuotes(grandchildSpec.parentIdField));
            }

            String gcQuery =
                'SELECT ' +
                String.join(gcValidatedFields, ', ') +
                ' FROM ' +
                String.escapeSingleQuotes(grandchildSpec.childObjectApiName) +
                ' WHERE ' +
                String.escapeSingleQuotes(grandchildSpec.parentIdField) +
                ' IN :parentIds';
            if (String.isNotBlank(grandchildSpec.whereClause)) {
                gcQuery += ' AND ' + sanitizeClause(grandchildSpec.whereClause, 'WHERE');
            }
            // Allowlist validation: ORDER BY fields verified against Schema.describeSObjects() field map
            if (String.isNotBlank(grandchildSpec.orderByClause)) {
                gcQuery += ' ORDER BY ' + sanitizeClause(grandchildSpec.orderByClause, 'ORDER BY', gcFieldMap);
            }
            if (String.isNotBlank(grandchildSpec.limitClause)) {
                gcQuery += ' LIMIT ' + sanitizeClause(grandchildSpec.limitClause, 'LIMIT');
            }

            List<SObject> gcResults;
            try {
                gcResults = Database.query(gcQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — all dynamic elements allowlist-validated against Schema.describeSObjects() field map; USER_MODE enforced
            } catch (Exception e) {
                // Grandchild query failed — skip this relationship
                continue;
            }

            // Group grandchild records by parent ID
            Map<Id, List<Map<String, Object>>> gcByParent = new Map<Id, List<Map<String, Object>>>();
            for (SObject gc : gcResults) {
                Id parentId = (Id) gc.get(grandchildSpec.parentIdField);
                if (!gcByParent.containsKey(parentId)) {
                    gcByParent.put(parentId, new List<Map<String, Object>>());
                }
                gcByParent.get(parentId).add(mapSObject(gc));
            }

            // Stitch into child records
            for (Object rec : childRecords) {
                if (!(rec instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> childRec = (Map<String, Object>) rec;
                Object childIdVal = childRec.get('Id');
                if (childIdVal == null) {
                    continue;
                }

                Id childId;
                try {
                    childId = Id.valueOf(String.valueOf(childIdVal));
                } catch (Exception e) {
                    // Non-ID value — skip stitching for this child record
                    continue;
                }

                List<Map<String, Object>> gcList = gcByParent.containsKey(childId)
                    ? gcByParent.get(childId)
                    : new List<Map<String, Object>>();

                childRec.put(
                    grandchildSpec.relationshipName,
                    new Map<String, Object>{ 'totalSize' => gcList.size(), 'records' => gcList }
                );
            }

            // Great-grandchildren (and deeper): if the grandchild spec has its
            // own children, aggregate all grandchild records across all parent
            // records into one synthetic data map and recurse. One SOQL per
            // depth level — scales to arbitrary nesting without N+1 queries.
            // Map mutations propagate back to the original data via shared refs.
            if (!grandchildSpec.children.isEmpty()) {
                List<Map<String, Object>> allGrandchildren = new List<Map<String, Object>>();
                for (Object rec : childRecords) {
                    if (!(rec instanceof Map<String, Object>)) {
                        continue;
                    }
                    Object wrapper = ((Map<String, Object>) rec).get(grandchildSpec.relationshipName);
                    if (!(wrapper instanceof Map<String, Object>)) {
                        continue;
                    }
                    Object recsObj = ((Map<String, Object>) wrapper).get('records');
                    if (!(recsObj instanceof List<Object>)) {
                        continue;
                    }
                    for (Object gc : (List<Object>) recsObj) {
                        if (gc instanceof Map<String, Object>) {
                            allGrandchildren.add((Map<String, Object>) gc);
                        }
                    }
                }
                if (!allGrandchildren.isEmpty()) {
                    Map<String, Object> syntheticParent = new Map<String, Object>{
                        grandchildSpec.relationshipName => new Map<String, Object>{
                            'totalSize' => allGrandchildren.size(),
                            'records' => allGrandchildren
                        }
                    };
                    stitchGrandchildren(syntheticParent, grandchildSpec);
                }
            }
        }
    }

    /**
     * Allowlist validation: field verified against Schema.describeSObjects() field map.
     * Returns the validated field name, or null if the field does not exist in the describe.
     */
    private static String validateField(String fieldName, Map<String, SObjectField> fieldMap) {
        if (String.isBlank(fieldName)) {
            return null;
        }

        if (fieldMap.containsKey(fieldName)) {
            return String.escapeSingleQuotes(fieldName);
        }

        // Try appending __c
        if (!fieldName.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldName + '__c')) {
            return String.escapeSingleQuotes(fieldName + '__c');
        }

        // Relationship field: Account.Name, Owner.Email, etc.
        if (fieldName.contains('.')) {
            List<String> relParts = fieldName.split('\\.');
            if (relParts.size() >= 2) {
                String relName = relParts[0];
                for (Schema.SObjectField sof : fieldMap.values()) {
                    if (sof.getDescribe().getRelationshipName() == relName) {
                        return String.escapeSingleQuotes(fieldName);
                    }
                }
            }
            return null;
        }

        return null;
    }

    /**
     * Allowlist validation: object verified against Schema.getGlobalDescribe().
     * Throws DocGenException if the object is blank or not found in the org's describe.
     */
    private static SObjectType validateObjectName(String objectName) {
        if (String.isBlank(objectName)) {
            throw new DocGenException('Object name is required.');
        }
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw new DocGenException('Invalid or inaccessible object: ' + objectName);
        }
        return objType;
    }

    /**
     * Allowlist validation: each field verified against Schema.describeSObjects() field map.
     * Silently drops fields not found in the describe (matching V1 behavior).
     */
    private static List<String> validateFieldList(List<String> fieldNames, SObjectType objType) {
        if (fieldNames == null || fieldNames.isEmpty()) {
            return new List<String>();
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();
        List<String> validated = new List<String>();
        for (String f : fieldNames) {
            String v = validateField(f.trim(), fieldMap);
            if (v != null) {
                validated.add(v);
            }
        }
        return validated;
    }

    // 1.72 — getPopulatedFieldsAsMap() strips child subqueries that returned
    // zero rows, so an empty child relationship has no key in the data map.
    // For every declared rel in the template's query config, ensure the
    // map contains at least { 'totalSize': 0, 'records': [] } so
    // {Rel.totalSize} renders 0 (not blank) and {#IF Rel.totalSize != 0}
    // evaluates false. Existing populated wrappers are left alone.
    private static void ensureChildRelKeys(Map<String, Object> data, List<String> relNames) {
        if (data == null || relNames == null) {
            return;
        }
        for (String rel : relNames) {
            if (String.isBlank(rel)) {
                continue;
            }
            if (!data.containsKey(rel)) {
                data.put(rel, new Map<String, Object>{ 'totalSize' => 0, 'records' => new List<Object>() });
            }
        }
    }

    /**
     * Recursively maps an SObject to a Map<String, Object>.
     * Child lists become { 'totalSize': N, 'records': [...] }.
     * Parent lookups become nested maps.
     */
    private static Map<String, Object> mapSObject(SObject record) {
        Map<String, Object> data = new Map<String, Object>();
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

        for (String key : populatedFields.keySet()) {
            try {
                Object value = populatedFields.get(key);

                if (value instanceof List<SObject>) {
                    List<Map<String, Object>> childList = new List<Map<String, Object>>();
                    for (SObject child : (List<SObject>) value) {
                        childList.add(mapSObject(child));
                    }
                    data.put(key, new Map<String, Object>{ 'totalSize' => childList.size(), 'records' => childList });
                } else if (value instanceof SObject) {
                    Map<String, Object> parentMap = mapSObject((SObject) value);
                    if (!parentMap.containsKey('Id')) {
                        try {
                            parentMap.put('Id', ((SObject) value).Id);
                        } catch (Exception ignored) {
                            // Parent record may not have Id populated — safe to skip
                            String noop = ignored.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                        }
                    }
                    data.put(key, parentMap);
                } else if (value instanceof Address) {
                    Address addr = (Address) value;
                    data.put(
                        key,
                        new Map<String, Object>{
                            'street' => addr.getStreet(),
                            'city' => addr.getCity(),
                            'state' => addr.getState(),
                            'postalCode' => addr.getPostalCode(),
                            'country' => addr.getCountry()
                        }
                    );
                } else if (value instanceof Location) {
                    Location loc = (Location) value;
                    data.put(
                        key,
                        new Map<String, Object>{ 'latitude' => loc.getLatitude(), 'longitude' => loc.getLongitude() }
                    );
                } else {
                    data.put(key, value);
                }
            } catch (Exception e) {
                // Intentionally swallowed — field mapping failed (e.g., blob field)
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }
        return data;
    }

    // ---------------------------------------------------------------------------
    // SOQL Clause Sanitization
    // ---------------------------------------------------------------------------

    /**
     * Validates a dynamic SOQL clause (WHERE, ORDER BY, or LIMIT fragment)
     * to prevent injection. Rejects clauses containing dangerous keywords.
     * Returns the clause if safe, throws DocGenException if not.
     */
    private static String sanitizeClause(String clause, String clauseType) {
        return sanitizeClause(clause, clauseType, null);
    }

    /**
     * Public wrapper so other controllers (e.g. DocGenController's template WHERE-clause evaluator)
     * can reuse the same sanitize rules without duplicating the keyword blocklist.
     */
    public static String sanitizeWhereClause(String clause) {
        return sanitizeClause(clause, 'WHERE');
    }

    /**
     * Sanitizes a SOQL clause (WHERE, ORDER BY, LIMIT) with keyword blocklist
     * and optional Schema allowlist validation for ORDER BY field names.
     * @param clause The raw clause value
     * @param clauseType One of 'WHERE', 'ORDER BY', 'LIMIT'
     * @param fieldMap Optional field map for allowlist validation of ORDER BY fields. Pass null to skip.
     */
    private static String sanitizeClause(String clause, String clauseType, Map<String, Schema.SObjectField> fieldMap) {
        if (String.isBlank(clause)) {
            return clause;
        }
        // Reject statement terminators and comments
        if (clause.contains(';') || clause.contains('--') || clause.contains('/*')) {
            throw new DocGenException('Invalid ' + clauseType + ' clause in query config.');
        }
        // Normalize whitespace for keyword matching
        String normalized = clause.replaceAll('\\s+', ' ').toUpperCase().trim();
        // LIMIT should be numeric only
        if (clauseType == 'LIMIT') {
            if (!clause.trim().isNumeric()) {
                throw new DocGenException('LIMIT clause must be a number.');
            }
            return clause;
        }
        // Reject DML and structural SOQL keywords that don't belong in clauses
        List<String> disallowed = new List<String>{
            'INSERT ',
            'UPDATE ',
            'DELETE ',
            'MERGE ',
            'UNDELETE ',
            'DROP ',
            'ALTER ',
            'CREATE ',
            'GRANT ',
            'REVOKE '
        };
        // WHERE clauses should not contain subqueries
        if (clauseType == 'WHERE') {
            disallowed.add('SELECT ');
        }
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw new DocGenException('Invalid ' + clauseType + ' clause: disallowed keyword detected.');
            }
        }
        // Allowlist validation: ORDER BY field names verified against Schema.describeSObjects() field map.
        // Accepts:
        //   - Direct fields:                Name
        //   - Custom relationship fields:   My_Lookup__r.Field   (resolved via My_Lookup__c)
        //   - Standard relationship fields: Account.Name         (resolved via AccountId)
        //                                   Product2.Name        (resolved via Product2Id)
        //   - Polymorphic/owner:            Owner.Name           (resolved via OwnerId)
        if (clauseType == 'ORDER BY' && fieldMap != null) {
            for (String part : clause.split(',')) {
                String fieldName = part.trim().split('\\s+')[0].toLowerCase();
                String baseField = fieldName.contains('.') ? fieldName.split('\\.')[0] : fieldName;
                if (fieldMap.containsKey(baseField)) {
                    continue;
                }
                // Custom relationship: My_Lookup__r → My_Lookup__c
                String asCustomLookup = baseField.endsWith('__r')
                    ? baseField.substring(0, baseField.length() - 3) + '__c'
                    : null;
                if (asCustomLookup != null && fieldMap.containsKey(asCustomLookup)) {
                    continue;
                }
                // Standard relationship: RelName → RelNameId (Account → AccountId, Product2 → Product2Id, Owner → OwnerId)
                String asStdLookup = baseField + 'id';
                if (fieldMap.containsKey(asStdLookup)) {
                    continue;
                }
                throw new DocGenException('Invalid field in ORDER BY: ' + fieldName);
            }
        }
        return clause; // CxSAST: SOQL injection mitigated by keyword blocklist + Schema allowlist validation for ORDER BY fields
    }

    /**
     * V4: Custom Apex Data Provider.
     * Config format: {"v":4,"provider":"MyClassName"}
     * Instantiates the named class (must implement DocGenDataProvider),
     * calls getData(recordId), and returns the result.
     */
    private static Map<String, Object> getRecordDataV4(Id recordId, Map<String, Object> config) {
        String providerClassName = (String) config.get('provider');
        if (String.isBlank(providerClassName)) {
            throw new DocGenException('V4 config requires a "provider" class name.');
        }

        // Resolve class — try plain name first, then with package namespace
        Type providerType = Type.forName(providerClassName);
        if (providerType == null) {
            providerType = Type.forName('portwoodglobal', providerClassName);
        }
        if (providerType == null) {
            throw new DocGenException(
                'Apex class "' + providerClassName + '" not found. Ensure it exists and implements DocGenDataProvider.'
            );
        }

        Object instance = providerType.newInstance();
        if (!(instance instanceof DocGenDataProvider)) {
            throw new DocGenException(
                'Class "' + providerClassName + '" must implement the DocGenDataProvider interface.'
            );
        }

        DocGenDataProvider provider = (DocGenDataProvider) instance;
        Map<String, Object> data = provider.getData(recordId);

        if (data == null) {
            throw new DocGenException('Data provider "' + providerClassName + '" returned null.');
        }

        return data;
    }

    /**
     * Counts child records per relationship for a given parent record.
     * Used by Giant Query to determine if async processing is needed.
     * Parses V3 query config to find child nodes and runs COUNT() for each.
     * @param recordId The parent record ID to count children for
     * @param queryConfigJson The V3 query configuration JSON string
     * @return Map of relationship name to child record count
     */
    public static Map<String, Integer> scoutChildCounts(Id recordId, String queryConfigJson) {
        Map<String, Integer> counts = new Map<String, Integer>();

        if (recordId == null || String.isBlank(queryConfigJson)) {
            return counts;
        }

        String trimmed = queryConfigJson.trim();

        if (trimmed.startsWith('{')) {
            // V3 or V2 JSON config
            scoutFromJsonConfig(recordId, trimmed, counts);
        } else {
            // V1 flat string — parse subqueries like (SELECT ... FROM RelName)
            scoutFromFlatConfig(recordId, trimmed, counts);
        }

        return counts;
    }

    /**
     * Scout child counts from a V1 flat string config.
     * Parses subquery patterns: (SELECT fields FROM RelationshipName)
     * Uses the parent record's SObjectType to resolve relationship → child object.
     */
    private static void scoutFromFlatConfig(Id recordId, String config, Map<String, Integer> counts) {
        // Find all subquery patterns: (SELECT ... FROM RelationshipName)
        Pattern subqueryPattern = Pattern.compile('(?i)\\(\\s*SELECT\\s+.+?\\s+FROM\\s+(\\w+)[^)]*\\)');
        Matcher m = subqueryPattern.matcher(config);

        // Get the parent object's child relationships to resolve rel name → child object + field
        String parentObjectType = String.valueOf(recordId.getSobjectType());
        Schema.DescribeSObjectResult parentDescribe = Schema.getGlobalDescribe().get(parentObjectType)?.getDescribe();
        if (parentDescribe == null) {
            return;
        }

        Map<String, Schema.ChildRelationship> relMap = new Map<String, Schema.ChildRelationship>();
        Map<String, Schema.ChildRelationship> objMap = new Map<String, Schema.ChildRelationship>();
        for (Schema.ChildRelationship cr : parentDescribe.getChildRelationships()) {
            if (cr.getRelationshipName() != null) {
                relMap.put(cr.getRelationshipName().toLowerCase(), cr);
                objMap.put(String.valueOf(cr.getChildSObject()).toLowerCase(), cr);
            }
        }

        while (m.find()) {
            String relName = m.group(1);
            Schema.ChildRelationship cr = relMap.get(relName.toLowerCase());
            // Fallback: user may have typed the object name instead of relationship name
            if (cr == null) {
                cr = objMap.get(relName.toLowerCase());
            }
            if (cr == null) {
                continue;
            }

            String childObject = String.valueOf(cr.getChildSObject());
            String lookupField = String.valueOf(cr.getField());

            try {
                String countQuery =
                    'SELECT COUNT() FROM ' +
                    String.escapeSingleQuotes(childObject) +
                    ' WHERE ' +
                    String.escapeSingleQuotes(lookupField) +
                    ' = :recordId';
                Integer cnt = Database.countQuery(countQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — childObject + lookupField escapeSingleQuotes'd; USER_MODE enforced
                counts.put(relName, cnt);
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — skip relationships that fail
            }
        }
    }

    /**
     * Scout child counts from a V3 (or V2) JSON config.
     * Parses nodes array to find child relationships and counts them.
     */
    private static void scoutFromJsonConfig(Id recordId, String configJson, Map<String, Integer> counts) {
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(configJson);

        // V2 format — has junctions and children arrays
        if (config.containsKey('children')) {
            List<Object> children = (List<Object>) config.get('children');
            if (children != null) {
                Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
                for (Object childObj : children) {
                    Map<String, Object> child = (Map<String, Object>) childObj;
                    String rel = (String) child.get('rel');
                    // V2 doesn't have object/lookupField directly — resolve from parent
                    // For now, use the same flat config approach for V2
                    if (String.isNotBlank(rel)) {
                        String parentObjectType = String.valueOf(recordId.getSobjectType());
                        Schema.DescribeSObjectResult parentDescribe = gd.get(parentObjectType)?.getDescribe();
                        if (parentDescribe != null) {
                            for (Schema.ChildRelationship cr : parentDescribe.getChildRelationships()) {
                                if (
                                    cr.getRelationshipName() != null && cr.getRelationshipName().equalsIgnoreCase(rel)
                                ) {
                                    try {
                                        String childObjName = String.valueOf(cr.getChildSObject());
                                        String lookupFld = String.valueOf(cr.getField());
                                        String countQ =
                                            'SELECT COUNT() FROM ' +
                                            String.escapeSingleQuotes(childObjName) +
                                            ' WHERE ' +
                                            String.escapeSingleQuotes(lookupFld) +
                                            ' = :recordId';
                                        counts.put(rel, Database.countQuery(countQ, AccessLevel.USER_MODE));
                                    } catch (Exception e) {
                                        String noop = e.getMessage(); // NOPMD UnusedLocalVariable
                                    }
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // V3 format — has nodes array
        List<Object> nodesJson = (List<Object>) config.get('nodes');
        if (nodesJson == null || nodesJson.isEmpty()) {
            return;
        }

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (Object nodeObj : nodesJson) {
            Map<String, Object> n = (Map<String, Object>) nodeObj;
            String parentNodeId = (String) n.get('parentNode');

            if (parentNodeId == null) {
                continue;
            }

            String childObject = (String) n.get('object');
            String lookupField = (String) n.get('lookupField');
            String relationshipName = (String) n.get('relationshipName');
            String alias = (String) n.get('alias');
            String whereClause = (String) n.get('where');
            // Counts must be keyed by the data-map key (alias when present) so
            // filtered subsets of the same relationship show up as separate rows
            // and the threshold check / giant routing can address each one.
            String countsKey = String.isNotBlank(alias) ? alias : relationshipName;

            if (String.isBlank(childObject) || String.isBlank(lookupField) || String.isBlank(relationshipName)) {
                continue;
            }

            // Allowlist validation: object must be in Schema.getGlobalDescribe()
            Schema.SObjectType childType = globalDescribe.get(childObject);
            if (childType == null) {
                continue;
            }

            // Allowlist validation: lookupField must be a real field on the child object.
            // Without this, a malicious V3 config could smuggle SOQL fragments like
            // 'Id != null OR Name' into the WHERE position via lookupField (escapeSingleQuotes
            // alone does not block keyword injection in unquoted SOQL identifiers). Mirrors
            // the validation getRecordDataV3 / getRecordDataV3Bulk perform on lookupField at
            // parse time (lines 597-603, 731-737).
            Map<String, Schema.SObjectField> childFieldMap = childType.getDescribe().fields.getMap();
            String validatedLookupField = validateField(lookupField, childFieldMap);
            if (validatedLookupField == null) {
                // Unknown field — skip this node rather than concatenating untrusted input
                counts.put(countsKey, 0);
                continue;
            }

            try {
                // CxSAST: SOQL injection mitigated by Schema allowlist validation on object,
                // lookupField + sanitizeClause keyword blocklist on WHERE + USER_MODE
                String countQuery =
                    'SELECT COUNT() FROM ' +
                    String.escapeSingleQuotes(childObject) +
                    ' WHERE ' +
                    validatedLookupField +
                    ' = :recordId';
                if (String.isNotBlank(whereClause)) {
                    countQuery += ' AND ' + sanitizeClause(whereClause, 'WHERE');
                }
                Integer cnt = Database.countQuery(countQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — childObject + lookupField allowlist-validated; whereClause sanitized; USER_MODE enforced
                counts.put(countsKey, cnt);
            } catch (Exception e) {
                // Intentionally swallowed — skip relationships that fail to count
                counts.put(countsKey, 0);
            }
        }
    }
}
