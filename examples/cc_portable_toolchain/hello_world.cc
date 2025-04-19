#include <iostream>
#include <vector>
#include <string>

int main()
{
    std::vector<std::string> greetings = {"Hello", "portable", "C++", "toolchain", "world!"};

    for (const auto &word : greetings)
    {
        std::cout << word << " ";
    }
    std::cout << std::endl;

    std::cout << "This binary was built with a portable Nixpkgs-based C++ toolchain" << std::endl;

    return 0;
}