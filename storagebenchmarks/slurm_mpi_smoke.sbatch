#!/bin/bash
#SBATCH --job-name=mpismoke
#SBATCH --partition=no_dinos
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=2
#SBATCH --output=/home/hpcadmin/storagebenchmarks/logs/mpismoke-%j.out
#SBATCH --error=/home/hpcadmin/storagebenchmarks/logs/mpismoke-%j.out
#SBATCH --time=00:05:00

echo "SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST"
echo "SLURM_NTASKS=$SLURM_NTASKS"
echo "--- mpirun under slurm allocation ---"
mpirun -n "$SLURM_NTASKS" /home/hpcadmin/storagebenchmarks/hello_bin
echo "--- exit=$? ---"
