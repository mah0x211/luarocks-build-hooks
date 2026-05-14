print("Running all tests...")
print("====================")
for _, test_file in ipairs({
    "test/resvars_test.lua",
    "test/resmodvars_test.lua",
    "test/hooks_test.lua",
    "test/extra-vars_test.lua",
    "test/pkgconfig_test.lua",
    "test/configh_test.lua",
}) do
    print("Running " .. test_file .. "...")
    print("--------------------")
    dofile(test_file)
    print("====================")
end

print("All tests completed successfully!")
