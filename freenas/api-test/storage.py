#!/usr/bin/env python3.6

# Author: Eric Turgeon
# License: BSD

import unittest
from functions import PUT, GET, POST
from config import disk1, disk2


class storage_test(unittest.TestCase):

    def test_storage1_Check_getting_disks(self):
        assert GET("/storage/disk/") == 200

    def test_storage2_Check_getting_disks(self):
        assert GET("/storage/volume/") == 200

    def test_storage3_Check_creating_a_zpool(self):
        payload = {"volume_name": "tank",
                   "layout": [{"vdevtype": "stripe", "disks": [disk1, disk2]}]}
        assert POST("/storage/volume/", payload) == 201

    def test_storage4_Check_creating_dataset_01_20_share(self):
        payload = {"name": "share"}
        assert POST("/storage/volume/tank/datasets/",payload) == 201

    def test_storage5_Check_creating_dataset_02_20_jails(self):
        payload = {"name": "jails"}
        assert POST("/storage/volume/tank/datasets/",payload) == 201

    def test_storage6_Changing_permissions_on_share(self):
        payload = {"mp_path": "/mnt/tank/share",
                   "mp_acl": "unix",
                   "mp_mode": "777",
                   "mp_user": "root",
                   "mp_group": "wheel"}
        assert PUT("/storage/permission/",payload) == 201

    def test_storage7_Changing_permissions_on_share(self):
        payload = {"mp_path": "/mnt/tank/jails",
                   "mp_acl": "unix",
                   "mp_mode": "777",
                   "mp_user": "root",
                   "mp_group": "wheel"}
        assert PUT("/storage/permission/", payload) == 201

    def test_storage8_Creating_a_ZFS_snapshot(self):
        payload = {"dataset": "tank", "name": "test"}
        assert POST("/storage/snapshot/",payload) == 201

    def test_storage9_Creating_dataset_for_testing_snapshot(self):
        payload = {"name": "snapcheck"}
        assert POST("/storage/volume/tank/datasets/",payload) == 201

    def test_storage10_Creating_a_ZVOL_1sur2(self):
        payload = {"name": "testzvol1", "volsize": "10M"}
        assert POST("/storage/volume/tank/zvols/",payload) == 201

    def test_storage11_Creating_a_ZVOL_2sur2(self):
        payload = {"name": "testzvol2", "volsize": "10M"}
        assert POST("/storage/volume/tank/zvols/",payload) == 201

if __name__ == "__main__":
    unittest.main(verbosity=2)
