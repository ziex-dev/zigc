rm -rf tmp
mkdir tmp
cd tmp

echo "version:"
npx --registry http://localhost:4873 @zigc/cli@master version
echo -e "\ninit:"
npx --registry http://localhost:4873 @zigc/cli@master init
echo -e "\nbuild:"
npx --registry http://localhost:4873 @zigc/cli@master build
echo -e "\nbuild run:"
npx --registry http://localhost:4873 @zigc/cli@master build run