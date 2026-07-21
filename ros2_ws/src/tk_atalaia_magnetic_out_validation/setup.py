import os
from glob import glob

from setuptools import find_packages, setup

package_name = 'tk_atalaia_magnetic_out_validation'

setup(
    name=package_name,
    version='0.0.1',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        (os.path.join('share', package_name, 'config'), glob('config/*')),
        (os.path.join('share', package_name, 'launch'), glob('launch/*')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='THEKER Testing',
    maintainer_email='TODO@theker.eu',
    description='TODO: Testing project package for tk_atalaia_magnetic_out_validation',
    license='TODO',
    entry_points={
        'console_scripts': [
            # Register nodes and GUIs here, e.g.:
            # 'lifecycle_test = tk_atalaia_magnetic_out_validation.nodes.lifecycle_test_node:main',
        ],
    },
)
