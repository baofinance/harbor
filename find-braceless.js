const parser = require('@solidity-parser/parser');
const fs = require('fs');
const path = require('path');
const chalk = require('chalk'); // Optional for colored output

function walkDir(dir, callback) {
    fs.readdirSync(dir).forEach(f => {
        let dirPath = path.join(dir, f);
        let isDirectory = fs.statSync(dirPath).isDirectory();
        if (isDirectory) {
            walkDir(dirPath, callback);
        } else if (f.endsWith('.sol')) {
            callback(path.join(dir, f));
        }
    });
}

function findBracelessControls(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');
    let issues = [];

    try {
        const ast = parser.parse(content, { loc: true });

        // Visit all nodes and find control statements
        parser.visit(ast, {
            IfStatement(node) {
                // Check if 'if' body is not a block
                if (node.trueBody && node.trueBody.type !== 'Block') {
                    issues.push({
                        type: 'if',
                        line: node.loc.start.line,
                        message: `Braceless if statement`
                    });
                }

                // Check if 'else' body is not a block and not an if
                if (node.falseBody && node.falseBody.type !== 'Block' && node.falseBody.type !== 'IfStatement') {
                    issues.push({
                        type: 'else',
                        line: node.loc.end.line,
                        message: `Braceless else statement`
                    });
                }
            },
            ForStatement(node) {
                // Check if 'for' body is not a block
                if (node.body && node.body.type !== 'Block') {
                    issues.push({
                        type: 'for',
                        line: node.loc.start.line,
                        message: `Braceless for loop`
                    });
                }
            },
            WhileStatement(node) {
                // Check if 'while' body is not a block
                if (node.body && node.body.type !== 'Block') {
                    issues.push({
                        type: 'while',
                        line: node.loc.start.line,
                        message: `Braceless while loop`
                    });
                }
            },
            DoWhileStatement(node) {
                // Check if 'do-while' body is not a block
                if (node.body && node.body.type !== 'Block') {
                    issues.push({
                        type: 'do-while',
                        line: node.loc.start.line,
                        message: `Braceless do-while loop`
                    });
                }
            },
            // Check for require/revert statements with unnecessary semicolons
            FunctionCall(node) {
                if (node.expression && node.expression.name) {
                    if (['require', 'revert', 'assert'].includes(node.expression.name)) {
                        const line = content.split('\n')[node.loc.start.line - 1];
                        if (line.trim().endsWith(';;')) {
                            issues.push({
                                type: node.expression.name,
                                line: node.loc.start.line,
                                message: `Redundant semicolon after ${node.expression.name}`
                            });
                        }
                    }
                }
            }
        });

        // Special handling for assembly blocks (using regex for inline assembly)
        const lines = content.split('\n');
        let inAssembly = false;
        let assemblyBraceCount = 0;

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();

            // Track assembly blocks
            if (line.includes('assembly')) {
                inAssembly = true;
                assemblyBraceCount += (line.match(/{/g) || []).length;
            }

            if (inAssembly) {
                // Count braces to track assembly block boundaries
                assemblyBraceCount += (line.match(/{/g) || []).length - (line.match(/}/g) || []).length;

                // Check for assembly for loops without braces
                if (line.includes('for') && !line.includes('{')) {
                    const nextLine = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
                    if (!nextLine.startsWith('{')) {
                        issues.push({
                            type: 'assembly-for',
                            line: i + 1,
                            message: `Braceless assembly for loop`
                        });
                    }
                }

                // End of assembly block
                if (assemblyBraceCount <= 0) {
                    inAssembly = false;
                }
            }
        }

        // Report issues
        if (issues.length > 0) {
            console.log(`\n${chalk?.blue(filePath) || filePath}:`);
            issues.sort((a, b) => a.line - b.line).forEach(issue => {
                console.log(`  ${filePath}:${issue.line}: ${chalk?.yellow(issue.message) || issue.message} (${issue.type})`);
            });
        }

        return issues.length;

    } catch (e) {
        console.error(`Error parsing ${filePath}: ${e.message}`);
        return 0;
    }
}

// Main execution
const directory = process.argv[2] || '.';
console.log(`Scanning for braceless control structures in: ${directory}`);

let totalFiles = 0;
let filesWithIssues = 0;
let totalIssues = 0;

walkDir(directory, (filePath) => {
    totalFiles++;
    const issues = findBracelessControls(filePath);
    if (issues > 0) {
        filesWithIssues++;
        totalIssues += issues;
    }
});

console.log(`\nScan complete:`);
console.log(`- Examined ${totalFiles} Solidity files`);
console.log(`- Found ${totalIssues} braceless control structures in ${filesWithIssues} files`);

if (totalIssues > 0) {
    console.log(`\nRecommendation: Add braces to all control structures for consistency and to prevent bugs.`);
}