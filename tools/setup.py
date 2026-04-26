from setuptools import find_packages, setup

setup(
    name="foxi",
    version="0.1.0",
    packages=find_packages(),
    package_data={"": ["../tricks/*.yaml"]},
    include_package_data=True,
    install_requires=["pyyaml"],
    entry_points={
        "console_scripts": [
            "foxi=foxi.cli:main",
        ],
    },
    python_requires=">=3.9",
)
