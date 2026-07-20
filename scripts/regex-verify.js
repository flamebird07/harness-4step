/**
 * regex-verify.js — static re-runnable test to verify regex patterns 
 * work correctly after Windows patch tool modifications.
 * 
 * Usage: node scripts/regex-verify.js
 * Run after EVERY patch involving regex on Windows to catch double-backslash bugs.
 */

const patterns = [
    // [name, pattern, input, expectedResult]
    ['label-batch', /^(?:批次|班次|小票)[：:]\s*\S+/, '批次:207812', true],
    ['label-customer', /^(?:客户)[：:]\s*\S+/, '客户:张三', true],
    ['label-address', /^(?:地址)[：:]\s*\S+/, '地址:广州', true],
    ['label-balance', /^(?:上次结余|累计结余)[：:]\s*\S+/, '上次结余:493', true],
    ['model-number', /^(?:款号)[：:]\s*\S+/, '款号:9910', true],
    ['sku-header', /^(?:商品信息|商品访客数|成交订单数)\s*$/, '成交订单数', true],
    ['dash-customer-info', /^-\s*(?:客户信息|订单编号|单据编号)/, '- 客户信息', true],
];

let failures = 0;
for (const [name, re, input, expected] of patterns) {
    const actual = re.test(input);
    const pass = actual === expected;
    if (!pass) failures++;
    console.log(`  [${pass ? 'PASS' : 'FAIL'}] ${name}: ${re}.test("${input}") = ${actual} (expected ${expected})`);
}

// Edge case: common Chinese shop names that should NOT match
const negatives = [
    ['shop-name', /^(?:批次|班次|小票|单号|单据号|款号|客户|地址|电话|上次结余|累计结余|总额|销数|退数)[：:]\s*\S+/, '九州佳丽销售退货单', false],
    ['shop-name-2', /^(?:批次|班次|小票|单号|单据号|款号|客户|地址|电话|上次结余|累计结余|总额|销数|退数)[：:]\s*\S+/, '欧洲城同花向往2楼043销售单', false],
];

for (const [name, re, input, expected] of negatives) {
    const actual = re.test(input);
    const pass = actual === expected;
    if (!pass) failures++;
    console.log(`  [${pass ? 'PASS' : 'FAIL'}] ${name} (negative): ${re}.test("${input}") = ${actual} (expected ${expected})`);
}

if (failures > 0) {
    console.error(`\n❌ ${failures} pattern(s) FAILED — likely double-backslash issue from patch tool`);
    process.exit(1);
} else {
    console.log('\n✅ All regex patterns valid');
}
