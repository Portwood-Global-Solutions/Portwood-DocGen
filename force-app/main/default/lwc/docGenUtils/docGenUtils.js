/**
 * Shared utility functions for DocGen LWC components.
 * Consolidates duplicated logic (download, filter parsing) into one module.
 */

/**
 * Downloads a base64-encoded file via a temporary anchor element.
 *
 * @param {string} base64Data - The base64-encoded file content
 * @param {string} fileName   - The download filename (including extension)
 * @param {string} mimeType   - The MIME type (e.g. 'application/pdf')
 */
export function downloadBase64(base64Data, fileName, mimeType) {
    const binaryString = atob(base64Data);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
        bytes[i] = binaryString.charCodeAt(i);
    }
    const blob = new Blob([bytes], { type: mimeType });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

/**
 * Converts a Query_Config__c JSON's report filters or bulkWhereClause
 * into a SOQL WHERE clause string.
 *
 * @param {string} queryConfigJson - Raw Query_Config__c value (JSON string)
 * @returns {string|null} The WHERE clause, or null if none could be derived
 */
/**
 * Splits a string by commas, respecting parenthesis nesting depth.
 * Port of Apex DocGenDataRetriever.splitTopLevel().
 *
 * @param {string} input - e.g. "Id, (SELECT Id FROM Cases)"
 * @returns {string[]} - e.g. ["Id", "(SELECT Id FROM Cases)"]
 */
export function splitTopLevel(input) {
    const parts = [];
    let current = '';
    let parenLevel = 0;

    for (let i = 0; i < input.length; i++) {
        const ch = input[i];

        // Auto-split field from adjacent subquery: "Account.Name (SELECT..."
        if (ch === '(' && parenLevel === 0 && current.trim().length > 0) {
            parts.push(current.trim());
            current = '';
        }

        if (ch === '(') {
            parenLevel++;
        }
        if (ch === ')') {
            parenLevel--;
        }

        if (ch === ',' && parenLevel === 0) {
            if (current.trim().length > 0) {
                parts.push(current.trim());
            }
            current = '';
        } else {
            current += ch;
        }
    }
    if (current.trim().length > 0) {
        parts.push(current.trim());
    }
    return parts;
}

/**
 * Finds a SQL keyword at parenthesis nesting level 0.
 * Returns the index of the keyword, or -1 if not found.
 *
 * @param {string} input - The string to search
 * @param {string} keyword - e.g. "FROM", "WHERE", "ORDER", "LIMIT"
 * @returns {number}
 */
export function findKeywordAtLevel0(input, keyword) {
    const upper = input.toUpperCase();
    const kw = keyword.toUpperCase();
    let parenLvl = 0;

    // Check at start of string
    if (upper.startsWith(kw + ' ') || upper.startsWith(kw + '\t') || upper.startsWith(kw + '\n')) {
        return 0;
    }

    for (let i = 0; i < input.length; i++) {
        const ch = input[i];
        if (ch === '(') {
            parenLvl++;
        }
        if (ch === ')') {
            parenLvl--;
        }
        if (parenLvl === 0) {
            // Check for keyword preceded by whitespace and followed by whitespace
            const before = input[i];
            if (/\s/.test(before) && i + 1 + kw.length <= upper.length) {
                const slice = upper.substring(i + 1, i + 1 + kw.length);
                const afterChar = upper[i + 1 + kw.length];
                if (slice === kw && (afterChar === undefined || /\s/.test(afterChar))) {
                    return i + 1; // position of keyword
                }
            }
        }
    }
    return -1;
}

/**
 * Parses a SOQL-like query string (V1 format) into base fields and subqueries.
 * Handles nested subqueries of any depth. Also accepts full SOQL statements
 * (with SELECT ... FROM ObjectName) — the outer SELECT/FROM are stripped.
 *
 * @param {string} queryStr - e.g. "Name, (SELECT Id, (SELECT Id FROM Cases) FROM Contacts)"
 *                            or "SELECT Name, (SELECT Id FROM Contacts) FROM Account"
 * @returns {{ baseFields: string[], parentFields: string[], subqueries: object[] }}
 */
export function parseSOQLFields(queryStr) {
    if (!queryStr) return { baseFields: [], parentFields: [], subqueries: [], warnings: [] };

    let cleaned = queryStr.trim();
    const warnings = [];

    // Detect and warn about outer WHERE/ORDER BY/LIMIT before stripping
    const outerClauses = detectOuterClauses(cleaned);
    if (outerClauses) {
        warnings.push(outerClauses);
    }

    // Strip outer SELECT ... FROM ObjectName if present
    cleaned = stripOuterSelectFrom(cleaned);

    // Split into top-level tokens (fields + subquery blocks)
    const tokens = splitTopLevel(cleaned);

    const baseFields = [];
    const parentFields = [];
    const subqueries = [];

    for (const token of tokens) {
        const trimmed = token.trim();
        const upper = trimmed.toUpperCase();
        if (trimmed.startsWith('(') && upper.includes('SELECT') && upper.includes('FROM')) {
            // Subquery
            const sq = parseSubquery(trimmed);
            if (sq) {
                subqueries.push(sq);
            }
        } else if (trimmed.length > 0) {
            if (trimmed.includes('.')) {
                parentFields.push(trimmed);
            } else {
                baseFields.push(trimmed);
            }
        }
    }

    return { baseFields, parentFields, subqueries, warnings };
}

/**
 * Detects if a full SOQL statement has WHERE/ORDER BY/LIMIT on the outer query.
 * These clauses are not supported at the top level because DocGen always runs
 * against a specific record.
 *
 * @param {string} input
 * @returns {string|null} Warning message, or null if clean
 */
function detectOuterClauses(input) {
    const upper = input.trim().toUpperCase();
    if (!upper.startsWith('SELECT ')) {
        return null;
    }

    const afterSelect = input.trim().substring(7);
    const fromIdx = findKeywordAtLevel0(afterSelect, 'FROM');
    if (fromIdx === -1) {
        return null;
    }

    const afterFrom = afterSelect.substring(fromIdx + 5).trim();
    // Check if there's more than just the object name after FROM
    const objOnly = afterFrom.match(/^(\w+)\s*$/);
    if (objOnly) {
        return null;
    } // Clean — just "FROM Account"

    const objMatch = afterFrom.match(/^(\w+)\s+/);
    if (!objMatch) {
        return null;
    }

    const remainder = afterFrom.substring(objMatch[0].length).trim().toUpperCase();
    const found = [];
    if (remainder.startsWith('WHERE') || remainder.includes(' WHERE ')) {
        found.push('WHERE');
    }
    if (remainder.includes('ORDER BY') || remainder.startsWith('ORDER')) {
        found.push('ORDER BY');
    }
    if (remainder.includes('LIMIT') || remainder.startsWith('LIMIT')) {
        found.push('LIMIT');
    }

    if (found.length > 0) {
        return (
            'Outer ' +
            found.join(', ') +
            ' clause' +
            (found.length > 1 ? 's are' : ' is') +
            ' ignored — DocGen runs against a specific record. Move filters inside a subquery if needed.'
        );
    }
    return null;
}

/**
 * Parses a single subquery string like "(SELECT Id, Name FROM Contacts WHERE ...)"
 * into a structured object. Recursively handles nested subqueries.
 *
 * @param {string} subqueryStr
 * @returns {{ relationshipName: string, fields: string[], children: object[], whereClause: string, orderBy: string, limitAmount: string }}
 */
function parseSubquery(subqueryStr) {
    // Strip outer parens
    let inner = subqueryStr.trim();
    if (inner.startsWith('(')) {
        inner = inner.substring(1);
    }
    if (inner.endsWith(')')) {
        inner = inner.substring(0, inner.length - 1);
    }
    inner = inner.trim();

    // Find SELECT and FROM at level 0
    const upperInner = inner.toUpperCase();
    const selectIdx = upperInner.indexOf('SELECT ');
    const fromIdx = findKeywordAtLevel0(inner, 'FROM');
    if (selectIdx === -1 || fromIdx === -1) {
        return null;
    }

    const fieldsPart = inner.substring(selectIdx + 7, fromIdx).trim();
    const afterFrom = inner.substring(fromIdx + 5).trim();

    // Extract relationship name and optional clauses
    const relMatch = afterFrom.match(/^(\w+)/);
    if (!relMatch) {
        return null;
    }
    const relationshipName = relMatch[1];
    let clauses = afterFrom.substring(relationshipName.length).trim();

    // Extract LIMIT
    let limitAmount = '';
    const limitMatch = clauses.match(/\s+LIMIT\s+(\d+)$/i);
    if (limitMatch) {
        limitAmount = limitMatch[1];
        clauses = clauses.substring(0, clauses.length - limitMatch[0].length).trim();
    }

    // Extract ORDER BY
    let orderBy = '';
    const orderMatch = clauses.match(/\s+ORDER\s+BY\s+(.+)$/i);
    if (orderMatch) {
        orderBy = orderMatch[1];
        clauses = clauses.substring(0, clauses.length - orderMatch[0].length).trim();
    }

    // Extract WHERE
    let whereClause = '';
    const whereMatch = clauses.match(/\s*WHERE\s+(.+)$/i);
    if (whereMatch) {
        whereClause = whereMatch[1];
    }

    // Parse fields, respecting nested subqueries
    const fieldTokens = splitTopLevel(fieldsPart);
    const fields = [];
    const children = [];

    for (const token of fieldTokens) {
        const trimmed = token.trim();
        const upper = trimmed.toUpperCase();
        if (trimmed.startsWith('(') && upper.includes('SELECT') && upper.includes('FROM')) {
            const child = parseSubquery(trimmed);
            if (child) {
                children.push(child);
            }
        } else if (trimmed.length > 0) {
            fields.push(trimmed);
        }
    }

    return { relationshipName, fields, children, whereClause, orderBy, limitAmount };
}

/**
 * Strips the outer SELECT ... FROM ObjectName from a full SOQL statement,
 * returning just the field list (including subqueries).
 *
 * @param {string} input - e.g. "SELECT Name, Industry FROM Account"
 * @returns {string} - e.g. "Name, Industry"
 */
export function stripOuterSelectFrom(input) {
    const trimmed = input.trim();
    const upper = trimmed.toUpperCase();

    // Must start with SELECT
    if (!upper.startsWith('SELECT ')) {
        return trimmed;
    }

    // Find FROM at level 0 (not inside a subquery)
    const afterSelect = trimmed.substring(7); // skip "SELECT "
    const fromIdx = findKeywordAtLevel0(afterSelect, 'FROM');
    if (fromIdx === -1) {
        return trimmed;
    }

    // Check that what follows FROM is a bare object name (not a subquery relationship)
    const afterFrom = afterSelect.substring(fromIdx + 5).trim();
    const objMatch = afterFrom.match(/^(\w+)\s*$/);
    if (!objMatch) {
        // Has WHERE/ORDER/LIMIT after the object — still strip for field extraction
        const objOnlyMatch = afterFrom.match(/^(\w+)/);
        if (objOnlyMatch) {
            return afterSelect.substring(0, fromIdx).trim();
        }
        return trimmed;
    }

    return afterSelect.substring(0, fromIdx).trim();
}

export function extractWhereClause(queryConfigJson) {
    if (!queryConfigJson) return null;

    try {
        const config = JSON.parse(queryConfigJson);

        if (config.bulkWhereClause) {
            return config.bulkWhereClause;
        }

        if (config.reportFilters && config.reportFilters.length > 0) {
            const DATE_LITERALS = [
                'TODAY',
                'YESTERDAY',
                'TOMORROW',
                'LAST_WEEK',
                'THIS_WEEK',
                'NEXT_WEEK',
                'LAST_MONTH',
                'THIS_MONTH',
                'NEXT_MONTH',
                'LAST_QUARTER',
                'THIS_QUARTER',
                'NEXT_QUARTER',
                'LAST_YEAR',
                'THIS_YEAR',
                'NEXT_YEAR',
                'LAST_90_DAYS',
                'NEXT_90_DAYS'
            ];

            const parts = config.reportFilters.map((f) => {
                if (f.operator === 'LIKE') {
                    return f.field + " LIKE '%" + f.value + "%'";
                }
                if (f.operator === 'IN' || f.operator === 'NOT IN') {
                    const vals = f.value
                        .split(',')
                        .map((v) => "'" + v.trim() + "'")
                        .join(', ');
                    return f.field + ' ' + f.operator + ' (' + vals + ')';
                }

                let v = f.value.trim();
                const upper = v.toUpperCase();

                // Date-only value on a datetime field: append time component
                const isDateOnly = /^\d{4}-\d{2}-\d{2}$/.test(v);
                const isDateTimeField =
                    f.field &&
                    (f.field.toLowerCase().includes('date') || f.field.toLowerCase().includes('time')) &&
                    !f.field.toLowerCase().endsWith('__c');
                if (isDateOnly && isDateTimeField) {
                    v = v + 'T00:00:00Z';
                }

                if (
                    DATE_LITERALS.includes(upper) ||
                    upper.startsWith('LAST_N_') ||
                    upper.startsWith('NEXT_N_') ||
                    /^\d+\.?\d*$/.test(v) ||
                    /^\d{4}-\d{2}-\d{2}/.test(v) ||
                    upper === 'TRUE' ||
                    upper === 'FALSE' ||
                    upper === 'NULL'
                ) {
                    return f.field + ' ' + f.operator + ' ' + v;
                }

                return f.field + ' ' + f.operator + " '" + f.value + "'";
            });

            return parts.join(' AND ');
        }
    } catch {
        // Not JSON or malformed — that's fine
    }

    return null;
}
