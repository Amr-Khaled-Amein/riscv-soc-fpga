#!/bin/bash
# rebuilds elfs/ from riscv-arch-test 4.1.0 (act4) with the config in config/
# needs: linux (wsl is fine), git, mise (for uv + ruby), build-essential,
#        xpack riscv-none-elf-gcc 15.2.0 and sail-riscv 0.13.1 in ~/opt (see test_config.yaml)
#
#   bash build.sh          # from this folder
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
[ -d $HOME/opt/act4 ] || git clone -q --depth 1 --branch 4.1.0 https://github.com/riscv-non-isa/riscv-arch-test.git $HOME/opt/act4
CFG=$HOME/act_cfg/rv32i_soc
rm -rf $CFG && mkdir -p $CFG
cp $HERE/config/* $CFG/
sed -i "s#/home/__USER__#$HOME#g" $CFG/test_config.yaml
cd $HOME/opt/act4
mise trust -y . && mise install -y
mise exec -- uv run act $CFG/test_config.yaml --workdir $HOME/act_work --test-dir tests --extensions I,Zicsr,Zifencei
rm -rf $HERE/elfs
for d in $HOME/act_work/rv32i_soc/elfs/rv32i/*; do
  mkdir -p $HERE/elfs/$(basename $d)
  cp $d/*.elf $HERE/elfs/$(basename $d)/
done
ls $HERE/elfs/*/*.elf | wc -l
