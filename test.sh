#!/bin/bash
#
# Testing script for tmpfs quota support
# (C)2022 Lukas Czerner <lukas [at] czerner.cz>

MNT=/mnt/test1
MNT1=/mnt/test2

GLOBAL_USR_INODE_LIMIT=0
GLOBAL_GRP_INODE_LIMIT=0
GLOBAL_USR_BLOCK_LIMIT=0
GLOBAL_GRP_BLOCK_LIMIT=0

USRQUOTA_ACTIVE=0
GRPQUOTA_ACTIVE=0

POPULATE_ARGS="10 18 20"
TESTUSER=fsgqa

error() {
	echo
	echo "ERROR: $@"
	umount $MNT >/dev/null 2>&1
	umount $MNT1 > /dev/null 2>&1
	exit 1
}

# [-u|-g] id used_blk limit_blk used_inode limit_inode
check_quota()
{
	expected="$3,$4,$5,$6"
	res=$(repquota -O csv $1 $MNT | grep "^#$2" | cut -d, -f4,6,8,10)

	echo -n "COMPARE \"$res\" and \"$expected\" ... "
	if [ "$res" != "$expected" ]; then
		echo "FAILED"
		exit 1
	else
		echo "OK"
	fi
}

_generate_usr_id()
{
	while true; do
		local id=$(( ($RANDOM % 30000) + 1500 ))
		[ -z "${USR_IDS[$id]}" ] && break
	done
	echo $id
}

_generate_grp_id()
{
	while true; do
		local id=$(( ($RANDOM % 30000) + 1500 ))
		[ -z "${GRP_IDS[$id]}" ] && break
	done
	echo $id
}

_chown()
{
	local fname=$MNT/$1
	local id=$2

	chown -h $id $fname || error "Can't change ownership of $fname to $id"
}

_create_file()
{
	local size=$1
	local fname=$MNT/$2

	xfs_io -f -c "pwrite -q -W 0 $size" "$fname" || error "File creation failed $fname"
}

_create_dir()
{
	local fname=$MNT/$1

	mkdir $fname || error "Directory creation failed $fname"
}

_create_symlink()
{
	local target=$MNT/$1
	local fname=$MNT/$2

	ln -s $target $fname || error "Symlink creation failed $fname"
}

_create_device()
{
	local type=$1
	local fname=$MNT/$2

	case $type in
		c) type="c 1 1";;
		b) type="b 1 1";;
		p) ;;
	esac

	mknod $fname $type || error "Device creation failed $fname, type = $type"
}

_setquota()
{
	local type=$1
	local id=$2
	local blimit=$3
	local ilimit=$4

	setquota $type $id 0 $blimit 0 $ilimit $MNT || error "Can't set quota: setquota $type $id 0 $blimit 0 $ilimit"
}

_set_usrquota()
{
	[ "$USRQUOTA_ACTIVE" -eq 1 ] || return
	_setquota -u $1 $2 $3
}

_set_grpquota()
{
	[ "$GRPQUOTA_ACTIVE" -eq 1 ] || return
	_setquota -g $1 $2 $3
}

# number_of_ids inodes_per_id blocks_per_id
# size is in blocks of 4096
populate_fs()
{
	local id_count=$1
	local inodes_per_id=$2
	local blocks_per_id=$3
	local inode_min=6

	[ $# -eq 3 ] || error "populate_fs() not enough arguments"

	if [ "$inodes_per_id" -lt "$inode_min" ]; then
		error "Inodes per id ($inodes_per_id) smaller than minimum ($inode_min)"
	fi
	
	#echo -n "Create $id_count IDs with $inodes_per_id inodes and $blocks_per_id blocks ... "
	for cnt in $(seq $id_count); do
		local extra_inodes=$(( $inodes_per_id % $inode_min ))
		local loops=$(( $inodes_per_id / $inode_min ))
		local size_limit=$(( ($blocks_per_id / $loops) * 2))
		local size_remaining=$blocks_per_id
		local grp_id=$(_generate_grp_id)
		local usr_id=$(_generate_usr_id)
		local usr_inode_limit=$GLOBAL_USR_INODE_LIMIT
		local usr_block_limit=$GLOBAL_USR_BLOCK_LIMIT
		local grp_inode_limit=$GLOBAL_GRP_INODE_LIMIT
		local grp_block_limit=$GLOBAL_GRP_BLOCK_LIMIT

		if [ "$size_limit" -eq 0 ]; then
			size_limit=1
		fi

		for i in $(seq $loops); do
			# Generate the new size, or use the remaining size
			if [ "$i" -eq "$loops" ]; then
				size=$size_remaining
			else
				size=$(_rand $size_limit)
			fi

			# Adjust the size
			if [ "$size_remaining" -gt "$size" ]; then
				size_remaining=$(( $size_remaining - $size ))
			else
				size=$size_remaining
				size_remaining=0
			fi

			suffix="${usr_id}_$i"

			_create_file $(( $size * 4096 )) "file_$suffix"
			_chown "file_$suffix" "$usr_id.$grp_id"

			_create_dir "dir_$suffix"
			_chown "dir_$suffix" "$usr_id.$grp_id"

			_create_symlink "file_$suffix" "symlink_${suffix}"
			_chown "symlink_${suffix}" "$usr_id.$grp_id"

			_create_device c "char_$suffix"
			_chown "char_$suffix" "$usr_id.$grp_id"

			_create_device b "block_$suffix"
			_chown "block_$suffix" "$usr_id.$grp_id"

			_create_device p "pipe_$suffix"
			_chown "pipe_$suffix" "$usr_id.$grp_id"
		done
		for i in $(seq $extra_inodes); do
			suffix="${usr_id}_$i"
			_create_file 0 "extrafile_$suffix"
			_chown "extrafile_$suffix" "$usr_id.$grp_id"
		done

		# Are we doing user setquota ?
		if [ $(($RANDOM % 2)) -eq 1 ] && [ $USRQUOTA_ACTIVE -eq 1 ]; then
			usr_inode_limit=$(($RANDOM + (2 * $inodes_per_id)))
			usr_block_limit=$((($RANDOM + (2 * $blocks_per_id * 4))))
			_set_usrquota $usr_id $usr_block_limit $usr_inode_limit
		fi

		# Are we doing group setquota ?
		if [ $(($RANDOM % 2)) -eq 1 ] && [ $GRPQUOTA_ACTIVE -eq 1 ]; then
			grp_inode_limit=$(($RANDOM + (2 * $inodes_per_id)))
			grp_block_limit=$((($RANDOM + (2 * $blocks_per_id * 4))))
			_set_grpquota $grp_id $grp_block_limit $grp_inode_limit
		fi

		USR_IDS[$usr_id]="#$usr_id,$(($blocks_per_id*4)),$usr_block_limit,$inodes_per_id,$usr_inode_limit"
		GRP_IDS[$grp_id]="#$grp_id,$(($blocks_per_id*4)),$grp_block_limit,$inodes_per_id,$grp_inode_limit"
	done

	sync -f $MNT
}

print_globals() {
	echo "= GLOBAL VARIABLES ="
	echo "USRQUOTA_ACTIVE=$USRQUOTA_ACTIVE"
	echo "GRPQUOTA_ACTIVE=$GRPQUOTA_ACTIVE"
	echo "GLOBAL_USR_INODE_LIMIT=$GLOBAL_USR_INODE_LIMIT"
	echo "GLOBAL_GRP_INODE_LIMIT=$GLOBAL_GRP_INODE_LIMIT"
	echo "GLOBAL_USR_BLOCK_LIMIT=$GLOBAL_USR_BLOCK_LIMIT"
	echo "GLOBAL_GRP_BLOCK_LIMIT=$GLOBAL_GRP_BLOCK_LIMIT"
}

compare_quota()
{
	local tmp=$(mktemp)

	if [ "$USRQUOTA_ACTIVE" -eq 1 ]; then
		repquota -u -O csv $MNT | grep "^#" | cut -d, -f1,4,6,8,10 | sort > ${tmp}.usrquota
		for id in "${!USR_IDS[@]}"; do
			echo ${USR_IDS[$id]}
		done | sort > ${tmp}.usr_ids

		if ! diff ${tmp}.usrquota ${tmp}.usr_ids 2>&1 > /dev/null; then
			echo "FAILED"
			echo
			diff -u ${tmp}.usrquota ${tmp}.usr_ids 2>&1
			echo
			print_globals
			error "User quota accounting differs from expectation (see diff -u ${tmp}.usrquota ${tmp}.usr_ids"
		fi
	fi

	if [ "$GRPQUOTA_ACTIVE" -eq 1 ]; then
		repquota -g -O csv $MNT | grep "^#" | cut -d, -f1,4,6,8,10 | sort > ${tmp}.grpquota
		for id in "${!GRP_IDS[@]}"; do
			echo ${GRP_IDS[$id]}
		done | sort > ${tmp}.grp_ids

		if ! diff ${tmp}.grpquota ${tmp}.grp_ids 2>&1 > /dev/null; then
			echo "FAILED"
			echo
			print_globals
			echo
			diff -u ${tmp}.grpquota ${tmp}.grp_ids 2>&1
			error "Group quota accounting differs from expectation (see diff -u ${tmp}.grpquota ${tmp}.grp_ids"
			
		fi
	fi

	rm -f $tmp.*
}

try_quota_limit()
{
	local add_space=0
	local add_inode=0
	local blimit=0
	local ilimit=0
	local space=0
	local icount=0

	for id in "${!USR_IDS[@]}"; do
		icount=$(echo ${USR_IDS[$id]} | cut -d, -f4)
		ilimit=$(echo ${USR_IDS[$id]} | cut -d, -f5)
		if [ $ilimit -ne 0 ]; then
			add_inode=$(($ilimit - $icount))
			if [ $add_inode -ge 0 ]; then
				echo "${USR_IDS[$id]} : icount=$icount ilimit=$ilimit add_inode=$add_inode"
				for i in $(seq $add_inode); do
					touch $MNT/testfile_$i || error "Can't create additional file"
				done
				chown $id $MNT/testfile_* || error "Can't chmod additional file"
				exit
				echo "Files created, test one more"
				touch $MNT/testfile_last || error "Can't create additional file"
				chown $id "$MNT/testfile_$i" && error "This should have failed"
				rm -rf $MNT/testfile_*
			fi
		fi
		
		bcount=$(echo ${USR_IDS[$id]} | cut -d, -f2)
		blimit=$(echo ${USR_IDS[$id]} | cut -d, -f3)
		if [ $blimit -ne 0 ]; then
			add_space=$(($blimit - $bcount))
			echo "${USR_IDS[$id]} : bcount=$bcount blimit=$blimit add_space=$add_space"
		fi
	done
}

quota_empty()
{
	if [ "$USRQUOTA_ACTIVE" -eq 1 ]; then
		cnt=$(repquota -u -O csv $MNT | grep "^#" | cut -d, -f1,4,6,8,10 | wc -l)
		[ $cnt -eq 0 ] || error "User quota list is NOT empty ($cnt)"
	fi

	if [ "$GRPQUOTA_ACTIVE" -eq 1 ]; then
		cnt=$(repquota -g -O csv $MNT | grep "^#" | cut -d, -f1,4,6,8,10 | wc -l)
		[ $cnt -eq 0 ] || error "Group quota list is NOT empty ($cnt)"
	fi
}

val_to_kb()
{
	val=$1
	num=${val%[kKmMgGtTpPeE]*}
	suffix=${val#*$num}

	cnt=$(echo -n $suffix | wc -c)
	[ "0$cnt" -gt 1 ] && error "Value $val is wrong"

	case $suffix in
		e | E)
			num=$(($num * 1024));&
		p | P)
			num=$(($num * 1024));&
		t | T)
			num=$(($num * 1024));&
		g | G)
			num=$(($num * 1024));&
		m | M)
			num=$(($num * 1024));&
		k | K)
			num=$(($num * 1024));&
		*)
			;;
	esac

	echo $(( ($num + 1023) / 1024 ))
}

_rand()
{
	max=$1
	if [ -z "$max" ]; then
		echo $(($RANDOM + 1))
	else
		echo $((($RANDOM % $max) + 1))
	fi
}

_mount() {
	declare -gA GPR_IDS
	declare -gA USR_IDS

	options=$1
	for i in $(echo $options | tr , ' '); do
		op=${i%=*}
		arg=${i#*=}
		case $op in
			"quota")
				USRQUOTA_ACTIVE=1
				GRPQUOTA_ACTIVE=1
				;;
			"usrquota")
				USRQUOTA_ACTIVE=1
				;;
			"grpquota")
				GRPQUOTA_ACTIVE=1
				;;
			"usrquota_inode_hardlimit")
				USRQUOTA_ACTIVE=1
				GLOBAL_USR_INODE_LIMIT=$arg
				;;
			"grpquota_inode_hardlimit")
				GRPQUOTA_ACTIVE=1
				GLOBAL_GRP_INODE_LIMIT=$arg
				;;
			"usrquota_block_hardlimit")
				USRQUOTA_ACTIVE=1
				GLOBAL_USR_BLOCK_LIMIT=$(val_to_kb $arg)
				;;
			"grpquota_block_hardlimit")
				GRPQUOTA_ACTIVE=1
				GLOBAL_GRP_BLOCK_LIMIT=$(val_to_kb $arg)
				;;
			*)
				error "Unknown mount option $arg"
				;;
		esac
	done
	if [ -z "$options" ]; then
		mount -t tmpfs none $MNT
	else
		mount -t tmpfs -o $options none $MNT
	fi
}

_umount() {
	umount $MNT
	GLOBAL_USR_INODE_LIMIT=0
	GLOBAL_GRP_INODE_LIMIT=0
	GLOBAL_USR_BLOCK_LIMIT=0
	GLOBAL_GRP_BLOCK_LIMIT=0
	USRQUOTA_ACTIVE=0
	GRPQUOTA_ACTIVE=0

	unset GRP_IDS
	unset USR_IDS
}

remove_random_files()
{
	local count=$1

	[ -n "$count" ] || error "Argumetn to remove_radnom_files() required"

	for file in $(find $MNT | shuf -n $count); do

		# Skip the mount point
		[ "$file" == "$MNT" ] && continue

		local st=$(stat --printf="%b,%u,%g" $file)
		local blocks=$(echo $st | cut -d, -f1)
		local user=$(echo $st | cut -d, -f2)
		local group=$(echo $st | cut -d, -f3)

		# blocks are in 512 blocks we need 1024
		blocks=$((blocks/2))

		rm -rf $file || error "Can't remove file \"$file\""
		USR_IDS[$user]=$(echo ${USR_IDS[$user]} | tr ',' ' ' | awk -v blocks=$blocks '{ $2=$2-blocks; $4--; print $0}' | tr ' ' ,)
		GRP_IDS[$group]=$(echo ${GRP_IDS[$group]} | tr ',' ' ' | awk -v blocks=$blocks '{ $2=$2-blocks; $4--; print $0}' | tr ' ' ,)
	done
}

test_populate()
{
	echo "[+] Testing accounting with options \"$1\""
	_mount $1
	populate_fs $POPULATE_ARGS
	compare_quota

	remove_random_files 15
	compare_quota

	# Mount backup tmpfs instance, copy over all files preserving attributes
	# and remove all files
	mount -t tmpfs none $MNT1
	mkdir $MNT1/backup
	cp -a $MNT/* $MNT1/backup/
	sync -f $MNT
	rm -rf $MNT/*

	# Files removed check if quota is removed as well
	quota_empty

	# Drop caches
	echo 3 > /proc/sys/vm/drop_caches
	echo 3 > /proc/sys/vm/drop_caches

	# Copy data back and test quota accounting. It should be the same
	# including changed quota limits
	cp -a $MNT1/backup/* $MNT/
	compare_quota

	umount $MNT1
	_umount
}


_all_combs()
{
	local gil=$1
	local gbl=$2
	local uil=$3
	local ubl=$4

	for i in {grpquota_inode_hardlimit=$gil,usrquota_inode_hardlimit=$uil,usrquota_block_hardlimit=$ubl,grpquota_block_hardlimit=$gbl},\
{grpquota_inode_hardlimit=$gil,usrquota_inode_hardlimit=$uil,usrquota_block_hardlimit=$ubl,grpquota_block_hardlimit=$gbl},\
{grpquota_inode_hardlimit=$gil,usrquota_inode_hardlimit=$uil,usrquota_block_hardlimit=$ubl,grpquota_block_hardlimit=$gbl},\
{grpquota_inode_hardlimit=$gil,usrquota_inode_hardlimit=$uil,usrquota_block_hardlimit=$ubl,grpquota_block_hardlimit=$gbl}; do
		x=$(echo $i | tr , '\n' | sort | uniq | tr '\n' ,); echo ${x%?};
	done | sort | uniq
}

test_populate_comb()
{
	local gil=$(_rand)
	local gbl=$(_rand)
	local uil=$(_rand)
	local ubl=$(_rand)

	# test all combinations of global limits
	for opts in $(_all_combs $gil $gbl $uil $ubl); do
		test_populate $opts
	done
}

_test_limit()
{
	local ilimit=$(_rand 50)
	# blimit is in 4K blocks
	local blimit=$(_rand 100)

	_setquota $1 $TESTUSER $((blimit * 4)) $ilimit

	sudo -u $TESTUSER xfs_io -f -c "pwrite -q -W 0 $(($blimit * 4096))" $MNT/testfile || error "Can't write file $fname"
	sudo -u $TESTUSER xfs_io -f -c "pwrite -q -W 0 $((($blimit + 1)* 4096))" $MNT/testfile > /dev/null 2>&1 && error "Quota enforcement failed $fname"

	for i in $(seq $((ilimit - 1))); do
		sudo -u $TESTUSER touch $MNT/testfile_$i || error "File cretion failed $fname"
	done

	sudo -u $TESTUSER touch $MNT/testfile_last >/dev/null 2>&1 && error "Quota enforcement failed $fname"
}

test_limit()
{
	_mount $1
	if [ "$USRQUOTA_ACTIVE" -eq 1 ]; then
		echo "[+] Testing user limit enforcement with options \"$1\""
		_test_limit -u
	fi
	_umount

	_mount $1
	if [ "$GRPQUOTA_ACTIVE" -eq 1 ]; then
		echo "[+] Testing group limit enforcement with options \"$1\""
		_test_limit -g
	fi
	_umount
}

test_global_limit()
{
	_mount $1

	[ "$GLOBAL_GRP_BLOCK_LIMIT" -gt 0 ] && [ "$GLOBAL_USR_BLOCK_LIMIT" -gt 0 ] && error "Don't set both user and group global block limits"
	[ "$GLOBAL_GRP_INODE_LIMIT" -gt 0 ] && [ "$GLOBAL_USR_INODE_LIMIT" -gt 0 ] && error "Don't set both user and group global inode limits"

	[ "$GLOBAL_GRP_BLOCK_LIMIT" -gt 0 ] && local blimit=$GLOBAL_GRP_BLOCK_LIMIT
	[ "$GLOBAL_USR_BLOCK_LIMIT" -gt 0 ] && local blimit=$GLOBAL_USR_BLOCK_LIMIT

	[ "$GLOBAL_GRP_INODE_LIMIT" -gt 0 ] && local ilimit=$GLOBAL_GRP_INODE_LIMIT
	[ "$GLOBAL_USR_INODE_LIMIT" -gt 0 ] && local ilimit=$GLOBAL_USR_INODE_LIMIT

	if [ -n "$blimit" ]; then
		echo "[+] Testing global block limit enforcement with option \"$1\""
		sudo -u $TESTUSER xfs_io -f -c "pwrite -q -W 0 $(($blimit * 1024))" $MNT/testfile || error "Can't write file $fname"
		sudo -u $TESTUSER xfs_io -f -c "pwrite -q -W 0 $((($blimit + 1)* 1024))" $MNT/testfile > /dev/null 2>&1 && error "Quota enforcement failed $fname"
	else
		sudo -u $TESTUSER touch $MNT/testfile || error "File cretion failed $fname"
	fi

	if [ -n "$ilimit" ]; then
		echo "[+] Testing global inode limit enforcement with option \"$1\""
		for i in $(seq $((ilimit - 1))); do
			sudo -u $TESTUSER touch $MNT/testfile_$i || error "File cretion failed $fname"
		done

		sudo -u $TESTUSER touch $MNT/testfile_last >/dev/null 2>&1 && error "Quota enforcement failed $fname"
	fi
	_umount
}

# Allow to set arguments to populate_fs()
if [ $# -eq 3 ]; then
	POPULATE_ARGS="$1 $2 $3"
fi

#===============================================================================
# TEST STARTS HERE
#===============================================================================

test_populate quota
test_populate usrquota
test_populate usrquota,quota
test_populate grpquota
test_populate grpquota,quota
test_populate grpquota,usrquota
test_populate grpquota,usrquota,quota

test_populate_comb
test_populate usrquota_block_hardlimit=$(_rand 200)m
test_populate grpquota_block_hardlimit=$(_rand 200)m

# Test the limits
test_limit quota
test_limit usrquota
test_limit usrquota,quota
test_limit grpquota
test_limit grpquota,quota
test_limit grpquota,usrquota
test_limit grpquota,usrquota,quota

test_global_limit usrquota_block_hardlimit=$(_rand 10)m
test_global_limit grpquota_block_hardlimit=$(_rand 10)m
test_global_limit usrquota_inode_hardlimit=$(_rand 20)
test_global_limit grpquota_inode_hardlimit=$(_rand 20)

test_global_limit usrquota_block_hardlimit=$(_rand 10)m,usrquota_inode_hardlimit=$(_rand 20)
test_global_limit grpquota_block_hardlimit=$(_rand 10)m,grpquota_inode_hardlimit=$(_rand 20)

test_global_limit usrquota_inode_hardlimit=$(_rand 20),grpquota_block_hardlimit=$(_rand 10)m
test_global_limit grpquota_inode_hardlimit=$(_rand 20),usrquota_block_hardlimit=$(_rand 10)m
