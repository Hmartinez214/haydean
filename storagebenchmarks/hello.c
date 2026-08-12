#include <mpi.h>
#include <stdio.h>
int main(int c,char**v){int r,s;char n[256];int l;
MPI_Init(&c,&v);MPI_Comm_rank(MPI_COMM_WORLD,&r);MPI_Comm_size(MPI_COMM_WORLD,&s);
MPI_Get_processor_name(n,&l);printf("rank %d/%d on %s\n",r,s,n);MPI_Finalize();return 0;}
