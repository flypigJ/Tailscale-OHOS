const fs = require('node:fs');

function verifySdkBaseline(profile) {
  const products = profile?.app?.products;
  if (!Array.isArray(products) || products.length === 0) {
    throw new Error('The build profile must declare at least one API 26 product.');
  }
  const fields = ['compileSdkVersion', 'compatibleSdkVersion', 'targetSdkVersion'];
  for (const product of products) {
    for (const field of fields) {
      if (product?.[field] !== '26.0.0') {
        throw new Error(`${field} must be explicitly set to 26.0.0 for every product; lower SDKs are not supported.`);
      }
    }
  }
  return products.length;
}

module.exports = { verifySdkBaseline };

if (require.main === module) {
  try {
    const JSON5 = require('json5');
    const productCount = verifySdkBaseline(JSON5.parse(fs.readFileSync(process.argv[2], 'utf8')));
    console.log(`Verified API 26-only SDK baseline for ${productCount} product(s).`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
