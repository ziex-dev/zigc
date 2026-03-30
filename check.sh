rm -rf tmp
mkdir tmp
cd tmp

echo "version:"
npx --registry http://localhost:4873 @zigc/cli version
echo -e "\ninit:"
npx --registry http://localhost:4873 @zigc/cli init
echo -e "\nbuild:"
npx --registry http://localhost:4873 @zigc/cli build
echo -e "\nbuild run:"
npx --registry http://localhost:4873 @zigc/cli build run